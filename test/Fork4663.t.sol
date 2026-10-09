// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SovrnToken} from "../src/SovrnToken.sol";
import {SovrnHook} from "../src/SovrnHook.sol";
import {LifeForceVault} from "../src/LifeForceVault.sol";
import {PoolRouter} from "./PoolRouter.sol";

/// @notice Rehearsal against the REAL Robinhood Chain (4663): the real IMD token and the real v4 PoolManager,
///         with our hook, vault and token deployed on a fork. Skipped unless FORK_4663_RPC is set, e.g.
///         FORK_4663_RPC=https://rpc.mainnet.chain.robinhood.com forge test --match-contract Fork4663 -vv
/// @dev A fork runs the local EVM's gas schedule, so this checks behaviour (real IMD semantics, real manager,
///      protocol-fee controller), not gas. Measure deployment gas with `cast estimate` against the real RPC.
abstract contract Fork4663Base is Test {
    address internal constant IMD_ADDR = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant REAL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant SAFE = 0xEb57c52272B90F989C41B739e2ccc5f00bF7697C;
    address internal constant TOKEN_ABOVE_IMD = address(0xF000000000000000000000000000000000000001);
    address internal constant TOKEN_BELOW_IMD = address(0x0000000000000000000000000000000000007001);
    uint160 internal constant START_PRICE = 79228162514264337593543950336000;

    IPoolManager internal manager = IPoolManager(REAL_MANAGER);
    ERC20 internal imd = ERC20(IMD_ADDR);
    SovrnToken internal token;
    SovrnHook internal hook;
    LifeForceVault internal vault;
    PoolRouter internal router;
    PoolKey internal key;

    function _imdIsCurrency0() internal view virtual returns (bool);

    function setUp() public {
        string memory rpc = vm.envOr("FORK_4663_RPC", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        require(block.chainid == 4663, "not chain 4663");
        require(REAL_MANAGER.code.length != 0 && IMD_ADDR.code.length != 0, "no real contracts");

        address tokenAt = _imdIsCurrency0() ? TOKEN_ABOVE_IMD : TOKEN_BELOW_IMD;
        deployCodeTo("SovrnToken.sol:SovrnToken", "", tokenAt);
        token = SovrnToken(tokenAt);
        address at = address(uint160(0x28cc));
        deployCodeTo("SovrnHook.sol:SovrnHook", abi.encode(manager, token, address(this)), at);
        hook = SovrnHook(payable(at));
        vault = hook.vault();
        assertEq(hook.imdIsCurrency0(), _imdIsCurrency0());

        key = _imdIsCurrency0()
            ? PoolKey(Currency.wrap(IMD_ADDR), Currency.wrap(address(token)), 12500, 60, IHooks(at))
            : PoolKey(Currency.wrap(address(token)), Currency.wrap(IMD_ADDR), 12500, 60, IHooks(at));
        manager.initialize(key, _orient(START_PRICE));

        // Real IMD: take some from the manager's own holdings (no minting cheats on a token we do not control).
        vm.prank(REAL_MANAGER);
        require(imd.transfer(address(this), 5_000 ether), "fund IMD");

        router = new PoolRouter(manager);
        token.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        router.liquidity(key, ModifyLiquidityParams(-887220, 887220, 1e22, bytes32(0)));
        vm.warp(hook.openedAt() + 1 hours); // past the launch decay: sells and buys both pay 3.5%
    }

    function _orient(uint160 p) internal view returns (uint160) {
        if (_imdIsCurrency0()) return p;
        uint256 m = (uint256(1) << 192) / uint256(p);
        if (m < TickMath.MIN_SQRT_PRICE + 1) m = TickMath.MIN_SQRT_PRICE + 1;
        if (m > TickMath.MAX_SQRT_PRICE - 1) m = TickMath.MAX_SQRT_PRICE - 1;
        return uint160(m);
    }

    function _trade(bool buy, int256 amount, uint160 limit) internal returns (BalanceDelta) {
        return router.trade(key, SwapParams(buy == _imdIsCurrency0(), amount, _orient(limit)));
    }

    function _imdLeg(BalanceDelta d) internal view returns (int128) {
        return _imdIsCurrency0() ? d.amount0() : d.amount1();
    }

    function _checkFee(bool buy, int256 amount, uint160 limit) internal {
        uint256 before = imd.balanceOf(address(vault));
        BalanceDelta d = _trade(buy, amount, limit);
        uint256 fee = imd.balanceOf(address(vault)) - before;
        int256 leg = int256(_imdLeg(d));
        uint256 gross = buy ? uint256(-leg) : uint256(leg) + fee;
        assertGt(fee, 0, "fee");
        assertEq(fee, gross * 350 / 10000, "3.5% of the IMD leg");
        assertEq(imd.balanceOf(address(hook)), 0, "hook holds IMD");
        assertEq(token.balanceOf(address(hook)), 0, "hook holds SVO");
        assertEq(hook.claimFees(), 0, "no claims needed: the real manager holds plenty of IMD");
    }

    function test_realIMDTransfersAreExact() public {
        uint256 b = imd.balanceOf(address(vault));
        assertTrue(imd.transfer(address(vault), 1_000 ether));
        assertEq(imd.balanceOf(address(vault)) - b, 1_000 ether, "no transfer fee into the vault");
        vault.sync();
        uint256 inference = vault.inferenceReserve();
        uint256 buyback = vault.buybackReserve();
        assertEq(inference + buyback, imd.balanceOf(address(vault)));
        assertEq(buyback, imd.balanceOf(address(vault)) * 3000 / 10000);
        uint256 safeBefore = imd.balanceOf(SAFE);
        vm.prank(SAFE);
        vault.withdrawInference(inference);
        assertEq(imd.balanceOf(SAFE) - safeBefore, inference, "no transfer fee out to the real Safe");
        vm.prank(SAFE);
        vault.withdrawBuyback(buyback);
        assertEq(imd.balanceOf(address(vault)), 0);
    }

    function test_feesOnTheRealManagerInAllFourModes() public {
        _checkFee(true, -0.1 ether, 4295128740);
        _checkFee(true, 10_000 ether, 4295128740);
        _checkFee(false, -10_000 ether, 1461446703485210103287273052203988822378723970341);
        _checkFee(false, 0.05 ether, 1461446703485210103287273052203988822378723970341);
        assertEq(vault.inferenceReserve() + vault.buybackReserve(), imd.balanceOf(address(vault)));
    }

    function test_safeWithdrawsFeesAndOnlyTheSafe() public {
        _checkFee(true, -1 ether, 4295128740);
        uint256 fees = imd.balanceOf(address(vault));
        assertGt(fees, 0);
        vm.expectRevert(LifeForceVault.Unauthorized.selector);
        vault.withdrawInference(1);
        uint256 reserve = vault.inferenceReserve();
        uint256 safeBefore = imd.balanceOf(SAFE);
        vm.prank(SAFE);
        vault.withdrawInference(reserve);
        assertEq(imd.balanceOf(SAFE) - safeBefore, reserve);
        assertEq(vault.inferenceReserve(), 0);
        assertEq(vault.buybackReserve(), imd.balanceOf(address(vault)));
    }

    function test_burnTheSVOHeldByTheVault() public {
        assertTrue(token.transfer(address(vault), 1_000 ether));
        vault.burn();
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(token.DEAD()), 1_000 ether);
    }

    function test_wrongKeyIsRejectedOnTheRealManager() public {
        // The hook binds exactly one pool: the same currencies with another fee tier cannot be initialized with it.
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert();
        manager.initialize(other, _orient(START_PRICE));
    }

    /// @dev The real manager's protocol-fee controller may assign this pool a protocol fee. It is outside our
    ///      control; log it so the rehearsal records it. The fee tests above already pass with whatever it is.
    function test_logTheProtocolFeeTheRealControllerAssigned() public {
        (,, uint24 protocolFee, uint24 lpFee) = StateLibrary.getSlot0(manager, key.toId());
        emit log_named_uint("protocol fee (packed 12+12 bits, 1/1,000,000 units)", protocolFee);
        emit log_named_uint("lp fee", lpFee);
        assertEq(lpFee, 12500);
    }
}

contract Fork4663ImdLowTest is Fork4663Base {
    function _imdIsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract Fork4663ImdHighTest is Fork4663Base {
    function _imdIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
