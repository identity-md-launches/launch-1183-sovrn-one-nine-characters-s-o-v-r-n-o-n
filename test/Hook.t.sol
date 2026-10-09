// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SystemBase} from "./SystemBase.sol";
import {SovrnHook} from "../src/SovrnHook.sol";
import {SovrnToken} from "../src/SovrnToken.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @dev Kept only because other suites still import it; no test here uses native ETH any more.
contract RejectETH {
    receive() external payable {
        revert();
    }
}

contract HookTest is SystemBase {
    function setUp() public {
        _system(true);
        vm.warp(hook.openedAt() + 1 hours);
    }

    function _checkFee(bool buy, int256 amount, uint160 limit) internal {
        uint256 beforeVault = _vaultIMD();
        BalanceDelta d = _trade(buy, amount, limit);
        uint256 fee = _vaultIMD() - beforeVault;
        uint256 gross = buy ? uint256(-int256(_imdLeg(d))) : uint256(int256(_imdLeg(d))) + fee;
        assertEq(fee, gross * 350 / 10000);
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertGt(fee, 0);
        if (buy && amount < 0) assertLe(gross, uint256(-amount));
        if (!buy && amount > 0) assertLe(uint256(int256(_imdLeg(d))), uint256(amount));
    }

    /// @dev Audit finding 7: a swap whose IMD leg rounds to a zero fee must not depend on IMD.balanceOf.
    function test_zeroFeeSwapDoesNotReadIMDBalance() public {
        vm.mockCallRevert(IMD_ADDR, abi.encodeWithSignature("balanceOf(address)", address(manager)), "paused");
        uint256 vaultBefore = _vaultIMD();
        BalanceDelta d = _trade(false, -1, 1461446703485210103287273052203988822378723970341);
        assertEq(_imdLeg(d), 0);
        assertEq(_vaultIMD(), vaultBefore);
    }

    function test_feeAllFourModes() public {
        _checkFee(true, -0.1 ether, 4295128740);
        _checkFee(true, 10_000 ether, 4295128740);
        _checkFee(false, -10_000 ether, 1461446703485210103287273052203988822378723970341);
        _checkFee(false, 0.05 ether, 1461446703485210103287273052203988822378723970341);
    }

    function test_partialBuyExactInput() public {
        _checkFee(true, -5 ether, START_PRICE * 99 / 100);
    }

    function test_partialBuyExactOutput() public {
        _checkFee(true, 5_000_000 ether, START_PRICE * 99 / 100);
    }

    function test_partialSellExactInput() public {
        _checkFee(false, -5_000_000 ether, START_PRICE * 101 / 100);
    }

    function test_partialSellExactOutput() public {
        _checkFee(false, 5 ether, START_PRICE * 101 / 100);
    }

    function test_exactModesRespectAmount() public {
        assertEq(_imdLeg(_trade(true, -0.1 ether)), -0.1 ether);
        assertEq(_svoLeg(_trade(true, 20_000 ether)), 20_000 ether);
        assertEq(_svoLeg(_trade(false, -20_000 ether)), -20_000 ether);
        assertEq(_imdLeg(_trade(false, 0.1 ether)), 0.1 ether);
    }

    function test_decayAndFullFeeToVault() public {
        uint256 opened = hook.openedAt();
        vm.warp(opened);
        assertEq(hook.launchFeeNow(), 0.5e18);
        assertEq(hook.decayMinutesLeft(), 60);
        _trade(true, -1 ether);
        assertEq(_vaultIMD(), 0.5 ether);
        assertEq(vault.inferenceReserve(), 0.35 ether);
        assertEq(vault.buybackReserve(), 0.15 ether);
        vm.warp(opened + 30 minutes);
        assertEq(hook.launchFeeNow(), 0.2675e18);
        assertEq(hook.decayMinutesLeft(), 30);
        vm.warp(opened + 1 hours);
        assertEq(hook.launchFeeNow(), 0.035e18);
        assertEq(hook.decayMinutesLeft(), 0);
        vm.warp(opened + 100 days);
        assertEq(hook.launchFeeNow(), 0.035e18);
    }

    function test_sellsStayAtNormalFee() public {
        _trade(true, -0.1 ether);
        vm.warp(hook.openedAt());
        _checkFee(false, -10_000 ether, 1461446703485210103287273052203988822378723970341);
    }

    function test_permissionsAndUnauthorizedCallbacks() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        hook.beforeInitialize(address(this), key, START_PRICE);
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, START_PRICE / 2), "");
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1 ether, START_PRICE / 2), BalanceDelta.wrap(0), "");
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        hook.unlockCallback("");
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        hook.quoteIMD(key, SwapParams(true, -1 ether, START_PRICE / 2));
    }

    function test_wrongPoolRejected() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert();
        manager.initialize(other, START_PRICE);
        other = key;
        other.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(other, START_PRICE);
    }

    function test_constructorHasNoChainGate() public {
        vm.chainId(1);
        deployCodeTo(
            "SovrnHook.sol:SovrnHook",
            abi.encode(IPoolManager(address(manager)), token, address(this)),
            address(uint160(0x68cc))
        );
    }

    /// @dev A second, uninitialized hook so beforeInitialize can be called directly (as the manager).
    function _freshHook() internal returns (SovrnHook h) {
        address at = address(uint160(0x68cc));
        deployCodeTo("SovrnHook.sol:SovrnHook", abi.encode(IPoolManager(address(manager)), token, address(this)), at);
        h = SovrnHook(payable(at));
    }

    function _copy(PoolKey memory k) internal pure returns (PoolKey memory) {
        return abi.decode(abi.encode(k), (PoolKey));
    }

    function test_beforeInitializeRejectsWrongKeys() public {
        SovrnHook h = _freshHook();
        PoolKey memory good = h.poolKey();
        good.tickSpacing = 60;
        // ETH-paired key (the old pool shape).
        PoolKey memory bad = _copy(good);
        bad.currency0 = Currency.wrap(address(0));
        bad.currency1 = Currency.wrap(address(token));
        vm.prank(address(manager));
        vm.expectRevert(SovrnHook.WrongPool.selector);
        h.beforeInitialize(address(this), bad, START_PRICE);
        // Currencies swapped against their address order.
        bad = _copy(good);
        bad.currency0 = good.currency1;
        bad.currency1 = good.currency0;
        vm.prank(address(manager));
        vm.expectRevert(SovrnHook.WrongPool.selector);
        h.beforeInitialize(address(this), bad, START_PRICE);
        // Wrong fee.
        bad = _copy(good);
        bad.fee = 3000;
        vm.prank(address(manager));
        vm.expectRevert(SovrnHook.WrongPool.selector);
        h.beforeInitialize(address(this), bad, START_PRICE);
        bad.fee = 0;
        vm.prank(address(manager));
        vm.expectRevert(SovrnHook.WrongPool.selector);
        h.beforeInitialize(address(this), bad, START_PRICE);
        // Only the factory may initialize; the right key from the right sender passes.
        vm.prank(address(manager));
        vm.expectRevert(SovrnHook.WrongPool.selector);
        h.beforeInitialize(ALICE, good, START_PRICE);
        vm.prank(address(manager));
        h.beforeInitialize(address(this), good, START_PRICE);
        assertTrue(h.initialized());
    }

    function test_poolKeyMatchesInitializedKey() public view {
        assertEq(abi.encode(hook.poolKey()), abi.encode(key));
        assertEq(Currency.unwrap(hook.poolKey().currency0), _imdIsCurrency0() ? IMD_ADDR : address(token));
        assertEq(Currency.unwrap(hook.poolKey().currency1), _imdIsCurrency0() ? address(token) : IMD_ADDR);
    }

    function test_hookHoldsNothingAfterEveryMode() public {
        int256[4] memory amounts = [int256(-0.1 ether), 10_000 ether, -10_000 ether, 0.05 ether];
        bool[4] memory buys = [true, true, false, false];
        for (uint256 i; i < 4; ++i) {
            _trade(buys[i], amounts[i]);
            assertEq(imd.balanceOf(address(hook)), 0);
            assertEq(token.balanceOf(address(hook)), 0);
            assertEq(hook.claimFees(), 0);
        }
    }

    function testFuzz_feeBuyAndSell(uint96 raw, bool buy, bool exactInput) public {
        uint256 amount = bound(uint256(raw), 1e12, 1e17);
        int256 specified = int256(buy == exactInput ? amount : amount * 1_000_000);
        if (exactInput) specified = -specified;
        _checkFee(buy, specified, buy ? 4295128740 : 1461446703485210103287273052203988822378723970341);
    }
}

contract HookReversedTest is HookTest {
    function _imdIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

/// @notice The claims path: the manager holds no IMD when the first buy's fee is taken, so the hook mints
///         ERC-6909 claims of currency id uint160(IMD) and redeemFees() moves them to the vault.
contract HookClaimsTest is SystemBase {
    function setUp() public {
        _systemAtPrice(false, LAUNCH_PRICE, 0);
        // All SVO at opening (range mirrored when IMD is currency1). A test range, not a launch allocation.
        if (_imdIsCurrency0()) {
            router.liquidity(key, ModifyLiquidityParams(166200, 184200, 1e21, bytes32(0)));
        } else {
            router.liquidity(key, ModifyLiquidityParams(-184200, -166200, 1e21, bytes32(0)));
        }
        assertEq(imd.balanceOf(address(manager)), 0);
    }

    function _claimId() internal pure returns (uint256) {
        return uint256(uint160(IMD_ADDR));
    }

    function testFuzz_firstBuyClaimsThenRedeemReachesVault(bool exactInput, uint16 elapsed) public {
        vm.warp(hook.openedAt() + bound(elapsed, 0, 7200));
        BalanceDelta first = _trade(true, exactInput ? -int256(0.01 ether) : int256(10_000 ether));
        uint256 gross = uint256(-int256(_imdLeg(first)));
        uint256 expected = gross * hook.launchFeeNow() / 1e18;
        assertGt(expected, 0);
        assertEq(hook.claimFees(), expected);
        assertEq(manager.balanceOf(address(hook), _claimId()), expected);
        assertEq(_vaultIMD(), 0);
        assertEq(vault.inferenceReserve() + vault.buybackReserve(), 0);
        vm.prank(BOB);
        hook.redeemFees();
        assertEq(hook.claimFees(), 0);
        assertEq(manager.balanceOf(address(hook), _claimId()), 0);
        assertEq(_vaultIMD(), expected);
        assertEq(vault.buybackReserve(), expected * 3000 / 10000);
        assertEq(vault.inferenceReserve(), expected - expected * 3000 / 10000);
        assertEq(imd.balanceOf(address(hook)), 0);
        hook.redeemFees();
        assertEq(_vaultIMD(), expected);
    }
}

contract HookClaimsReversedTest is HookClaimsTest {
    function _imdIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
