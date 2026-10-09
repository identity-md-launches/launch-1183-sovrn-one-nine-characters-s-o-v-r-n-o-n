// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SystemBase} from "./SystemBase.sol";
import {SovrnHook} from "../src/SovrnHook.sol";
import {SovrnToken} from "../src/SovrnToken.sol";
import {LifeForceVault} from "../src/LifeForceVault.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @dev Records the outcome of a re-entrant call made from inside IMD's transfer.
contract ReentryRecorder {
    bool public succeeded;
    bytes public reason;
    bool public called;

    function record(bool ok, bytes calldata r) external {
        called = true;
        succeeded = ok;
        reason = r;
    }
}

/// @dev A hostile IMD: same ERC-20 storage layout as MockIMD (etched over it), but every transfer to the
///      vault first tries to call hook.redeemFees() while the hook is mid-swap. No storage of its own.
contract ReentrantIMD is ERC20 {
    SovrnHook private immutable hook;
    ReentryRecorder private immutable recorder;

    constructor(SovrnHook h, ReentryRecorder r) ERC20("Identity.md", "IMD", 18) {
        hook = h;
        recorder = r;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == address(hook.vault())) {
            (bool ok, bytes memory reason) = address(hook).call(abi.encodeCall(hook.redeemFees, ()));
            recorder.record(ok, reason);
        }
        balanceOf[msg.sender] -= amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(msg.sender, to, amount);
        return true;
    }
}

contract SecurityTest is SystemBase {
    function setUp() public {
        _system(true);
    }

    function test_exactPermissionsAndFlags() public view {
        Hooks.Permissions memory expected;
        expected.beforeInitialize = true;
        expected.beforeAddLiquidity = true;
        expected.beforeSwap = true;
        expected.afterSwap = true;
        expected.beforeSwapReturnDelta = true;
        expected.afterSwapReturnDelta = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));
        assertEq(HookFlags.SOVRN_FLAGS, 10444);
        assertEq(HookFlags.flagsOf(address(hook)), 10444);
        assertEq(abi.encode(hook.poolKey()), abi.encode(key));
    }

    function test_firstInitEveryFieldAndSecondInitRejected() public {
        address at = address(uint160(0xa8cc));
        deployCodeTo("SovrnHook.sol:SovrnHook", abi.encode(manager, token, address(this)), at);
        SovrnHook fresh = SovrnHook(payable(at));
        PoolKey memory correct = key;
        correct.hooks = IHooks(at);
        assertEq(fresh.launchFeeNow(), 0.5e18);
        assertEq(fresh.decayMinutesLeft(), 60);
        vm.prank(address(manager));
        vm.expectRevert(SovrnHook.WrongPool.selector);
        fresh.beforeSwap(address(router), correct, SwapParams(true, -1, START_PRICE / 2), "");
        for (uint256 i; i < 7; ++i) {
            PoolKey memory bad = abi.decode(abi.encode(correct), (PoolKey));
            if (i == 0) bad.currency0 = Currency.wrap(ALICE);
            if (i == 1) bad.currency1 = Currency.wrap(ALICE);
            if (i == 2) bad.fee = 3000;
            if (i == 3) bad.tickSpacing = 0;
            if (i == 4) bad.tickSpacing = -60;
            if (i == 5) bad.hooks = IHooks(ALICE);
            vm.prank(address(manager));
            vm.expectRevert(SovrnHook.WrongPool.selector);
            fresh.beforeInitialize(i == 6 ? ALICE : address(this), bad, START_PRICE);
            assertFalse(fresh.initialized());
        }
        manager.initialize(correct, _orient(START_PRICE));
        assertTrue(fresh.initialized());
        vm.prank(address(manager));
        vm.expectRevert(SovrnHook.WrongPool.selector);
        fresh.beforeInitialize(address(this), correct, START_PRICE);
    }

    function test_constructorCodeChecksAndInvalidFlags() public {
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        new SovrnHook(IPoolManager(ALICE), token, address(this));
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        new SovrnHook(manager, SovrnToken(ALICE), address(this));
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        new SovrnHook(manager, token, address(0));
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        new SovrnHook(manager, SovrnToken(IMD_ADDR), address(this));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertFalse(HookFlags.matches(predicted, HookFlags.SOVRN_FLAGS));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new SovrnHook(manager, token, address(this));
        vm.expectRevert(LifeForceVault.Unauthorized.selector);
        new LifeForceVault(IPoolManager(ALICE), token, address(hook));
        vm.expectRevert(LifeForceVault.Unauthorized.selector);
        new LifeForceVault(manager, SovrnToken(ALICE), address(hook));
        vm.expectRevert(LifeForceVault.Unauthorized.selector);
        new LifeForceVault(manager, token, address(0));
    }

    /// @dev IMD analogue of a vault that rejects ETH: a vault that refuses IMD makes the direct take revert.
    function test_directFeeRejectionRollsBackSwapAndBusyGuard() public {
        imd.setRefuses(address(vault), true);
        uint256 oldIMD = imd.balanceOf(address(manager));
        uint256 oldTokens = token.balanceOf(address(this));
        vm.expectRevert();
        _trade(true, -1 ether);
        assertEq(imd.balanceOf(address(manager)), oldIMD);
        assertEq(token.balanceOf(address(this)), oldTokens);
        assertEq(hook.claimFees(), 0);
        imd.setRefuses(address(vault), false);
        _trade(true, -1 ether);
        assertEq(_vaultIMD(), 0.5 ether);
    }

    /// @dev IMD analogue of a false-returning/failed transfer: the swap reverts whole and recovers afterwards.
    function test_imdReturningFalseRollsBackSwap() public {
        imd.setReturnFalse(true);
        uint256 oldIMD = imd.balanceOf(address(this));
        vm.expectRevert();
        _trade(true, -1 ether);
        assertEq(imd.balanceOf(address(this)), oldIMD);
        assertEq(hook.claimFees(), 0);
        assertEq(_vaultIMD(), 0);
        imd.setReturnFalse(false);
        _trade(true, -1 ether);
        assertEq(_vaultIMD(), 0.5 ether);
    }

    /// @dev Replaces the ETH receive() re-entry probe: a hostile IMD calls redeemFees() from inside the fee
    ///      transfer to the vault. The hook is mid-swap, so it reverts Busy.
    function test_feeCallbackCannotReenterRedemption() public {
        ReentryRecorder rec = new ReentryRecorder();
        vm.etch(IMD_ADDR, address(new ReentrantIMD(hook, rec)).code);
        _trade(true, -1 ether);
        assertTrue(rec.called());
        assertFalse(rec.succeeded());
        assertEq(rec.reason(), abi.encodeWithSelector(SovrnHook.Busy.selector));
        assertEq(_vaultIMD(), 0.5 ether);
    }

    /// @dev Every hook entry point reverts unless msg.sender is the PoolManager, so no token callback or
    ///      outsider can drive the hook's swap/redeem state machine.
    function test_hookCallbacksRejectEveryoneButThePoolManager() public {
        SwapParams memory sp = SwapParams(true, -1 ether, _orient(START_PRICE / 2));
        address[3] memory callers = [ALICE, address(vault), address(router)];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(SovrnHook.Unauthorized.selector);
            hook.beforeInitialize(callers[i], key, START_PRICE);
            vm.expectRevert(SovrnHook.Unauthorized.selector);
            hook.beforeSwap(callers[i], key, sp, "");
            vm.expectRevert(SovrnHook.Unauthorized.selector);
            hook.afterSwap(callers[i], key, sp, BalanceDelta.wrap(0), "");
            vm.expectRevert(SovrnHook.Unauthorized.selector);
            hook.unlockCallback(abi.encode(uint256(1)));
            vm.expectRevert(SovrnHook.Unauthorized.selector);
            hook.quoteIMD(key, sp);
            vm.stopPrank();
        }
        // Even the manager cannot run the redemption callback outside a redeemFees() call.
        vm.prank(address(manager));
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        hook.unlockCallback(abi.encode(uint256(1)));
    }

    function test_noAdministrationEvenForFactoryOrSafe() public {
        string[8] memory signatures = [
            "owner()",
            "transferOwnership(address)",
            "setOwner(address)",
            "upgradeTo(address)",
            "pause()",
            "setVault(address)",
            "setFee(uint256)",
            "setSafe(address)"
        ];
        address[3] memory targets = [address(token), address(hook), address(vault)];
        address[3] memory callers = [address(this), vault.REFUEL_SAFE(), ALICE];
        for (uint256 i; i < targets.length; ++i) {
            for (uint256 j; j < signatures.length; ++j) {
                for (uint256 k; k < callers.length; ++k) {
                    vm.prank(callers[k]);
                    (bool ok,) = targets[i].call(abi.encodeWithSignature(signatures[j], ALICE));
                    assertFalse(ok, signatures[j]);
                }
            }
        }
    }

    function test_runtimeHasNoEscapeOpcodes() public view {
        _scan(address(token));
        _scan(address(hook));
        _scan(address(vault));
    }

    function _scan(address target) private view {
        bytes memory code = target.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }
}

/// @dev Same suite with IMD as the higher address (currency1).
contract SecurityReversedTest is SecurityTest {
    function _imdIsCurrency0() internal view override returns (bool) {
        return false;
    }
}
