// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SovrnToken} from "../src/SovrnToken.sol";
import {SovrnHook} from "../src/SovrnHook.sol";
import {LifeForceVault} from "../src/LifeForceVault.sol";
import {PoolRouter} from "./PoolRouter.sol";
import {MockIMD} from "./mocks/MockERC20.sol";

/// @dev Shared fixture. IMD is a mock placed at its real Robinhood Chain address, the chain id is 4663, and the
///      SVO token sits at a chosen address so a suite can run with IMD as currency0 (default) or as currency1
///      (override `_imdIsCurrency0`). Every price limit and start price a test passes is written for the
///      "IMD is currency0" orientation; for the other order the fixture mirrors it (price -> 2^192 / price), so
///      the same test body checks the same behaviour in both orders. "buy" always means IMD in, SVO out.
abstract contract SystemBase is Test {
    PoolManager internal manager;
    SovrnToken internal token;
    SovrnHook internal hook;
    LifeForceVault internal vault;
    PoolRouter internal router;
    MockIMD internal imd;
    PoolKey internal key;
    address internal constant IMD_ADDR = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant TOKEN_ABOVE_IMD = address(0xF000000000000000000000000000000000000001);
    address internal constant TOKEN_BELOW_IMD = address(0x0000000000000000000000000000000000007001);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    uint160 internal constant START_PRICE = 79228162514264337593543950336000;
    uint160 internal constant LAUNCH_PRICE = 792281625142643375935439503360000;

    /// @dev Override to false to run a suite with IMD as the HIGHER address (currency1).
    function _imdIsCurrency0() internal view virtual returns (bool) {
        return true;
    }

    function _system(bool seed) internal {
        _systemAtPrice(seed, START_PRICE, 1e22);
    }

    function _systemAtPrice(bool seed, uint160 initialPrice, int256 liquidity) internal {
        vm.chainId(4663);
        manager = new PoolManager(address(this));
        deployCodeTo("MockERC20.sol:MockIMD", abi.encode(uint256(1e33)), IMD_ADDR);
        imd = MockIMD(IMD_ADDR);
        address tokenAt = _imdIsCurrency0() ? TOKEN_ABOVE_IMD : TOKEN_BELOW_IMD;
        deployCodeTo("SovrnToken.sol:SovrnToken", "", tokenAt);
        token = SovrnToken(tokenAt);
        address at = address(uint160(0x28cc));
        deployCodeTo("SovrnHook.sol:SovrnHook", abi.encode(IPoolManager(address(manager)), token, address(this)), at);
        hook = SovrnHook(payable(at));
        vault = hook.vault();
        assertEq(hook.imdIsCurrency0(), _imdIsCurrency0());
        key = _imdIsCurrency0()
            ? PoolKey(Currency.wrap(IMD_ADDR), Currency.wrap(address(token)), 12500, 60, IHooks(at))
            : PoolKey(Currency.wrap(address(token)), Currency.wrap(IMD_ADDR), 12500, 60, IHooks(at));
        manager.initialize(key, _orient(initialPrice));
        router = new PoolRouter(manager);
        token.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        token.transfer(ALICE, 10_000_000 ether);
        token.transfer(BOB, 10_000_000 ether);
        imd.transfer(ALICE, 100 ether);
        imd.transfer(BOB, 100 ether);
        vm.startPrank(ALICE);
        token.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        vm.stopPrank();
        if (seed) {
            router.liquidity(key, ModifyLiquidityParams(-887220, 887220, liquidity, bytes32(0)));
        }
    }

    /// @dev Mirror a sqrt price written for "IMD is currency0" into this fixture's orientation.
    function _orient(uint160 p) internal view returns (uint160) {
        if (_imdIsCurrency0()) return p;
        uint256 m = (uint256(1) << 192) / uint256(p);
        if (m < TickMath.MIN_SQRT_PRICE + 1) m = TickMath.MIN_SQRT_PRICE + 1;
        if (m > TickMath.MAX_SQRT_PRICE - 1) m = TickMath.MAX_SQRT_PRICE - 1;
        return uint160(m);
    }

    /// @param limit price limit written for the "IMD is currency0" orientation.
    function _trade(bool buy, int256 amount, uint160 limit) internal returns (BalanceDelta) {
        bool zeroForOne = buy == _imdIsCurrency0();
        return router.trade(key, SwapParams(zeroForOne, amount, _orient(limit)));
    }

    function _trade(bool buy, int256 amount) internal returns (BalanceDelta) {
        return _trade(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    /// @dev The IMD / SVO legs of a swap delta, whichever slot each one occupies.
    function _imdLeg(BalanceDelta d) internal view returns (int128) {
        return _imdIsCurrency0() ? d.amount0() : d.amount1();
    }

    function _svoLeg(BalanceDelta d) internal view returns (int128) {
        return _imdIsCurrency0() ? d.amount1() : d.amount0();
    }

    function _vaultIMD() internal view returns (uint256) {
        return imd.balanceOf(address(vault));
    }
}
