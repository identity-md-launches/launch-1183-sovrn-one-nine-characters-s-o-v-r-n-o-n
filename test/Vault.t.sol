// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SystemBase} from "./SystemBase.sol";
import {LifeForceVault} from "../src/LifeForceVault.sol";
import {SovrnToken} from "../src/SovrnToken.sol";
import {Guard} from "../src/Interfaces.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @dev Installed at the Safe. Re-enters the vault from the IMD transfer callback (an ERC-777 style token).
contract SafeReentryProbe {
    LifeForceVault private immutable vault;
    bool public inferenceOK;
    bool public buybackOK;
    bytes public inferenceError;
    bytes public buybackError;

    constructor(LifeForceVault v) {
        vault = v;
    }

    function tokensReceived(uint256) external {
        (inferenceOK, inferenceError) = address(vault).call(abi.encodeCall(vault.withdrawInference, (1)));
        (buybackOK, buybackError) = address(vault).call(abi.encodeCall(vault.withdrawBuyback, (1)));
        require(
            IERC20Like(vault.IMD()).balanceOf(address(vault)) == vault.inferenceReserve() + vault.buybackReserve(),
            "callback accounting"
        );
    }
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}

/// @dev Kept only so suites not yet ported still compile; nothing in the vault suites uses it.
contract ForceETH {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}

contract VaultTest is SystemBase {
    event LifeForceFunded(address indexed from, uint256 amount, uint256 inference, uint256 buyback);
    event InferenceWithdrawn(uint256 amount);
    event BuybackWithdrawn(uint256 amount);
    event Burned(uint256 amount);

    address internal safe;

    function setUp() public {
        _system(false);
        safe = vault.REFUEL_SAFE();
    }

    /// @dev IMD sent straight to the vault (it has no hook for deposits), then checkpointed.
    function _fund(uint256 amount) internal {
        assertTrue(imd.transfer(address(vault), amount));
        vault.sync();
    }

    function test_splitRoundingAndEvents() public {
        assertEq(vault.REFUEL_SAFE(), 0xEb57c52272B90F989C41B739e2ccc5f00bF7697C);
        assertEq(vault.IMD(), IMD_ADDR);
        assertEq(vault.imd(), IMD_ADDR);
        assertEq(vault.INFERENCE_BPS(), 7000);
        assertEq(vault.BUYBACK_BPS(), 3000);
        for (uint256 i; i <= 11; ++i) {
            uint256 beforeInference = vault.inferenceReserve();
            uint256 beforeBuyback = vault.buybackReserve();
            assertTrue(imd.transfer(address(vault), i));
            if (i != 0) {
                vm.expectEmit(true, false, false, true, address(vault));
                emit LifeForceFunded(address(0), i, i - i * 3 / 10, i * 3 / 10);
            }
            vault.sync();
            assertEq(vault.inferenceReserve() - beforeInference, i - i * 3 / 10);
            assertEq(vault.buybackReserve() - beforeBuyback, i * 3 / 10);
            assertEq(_vaultIMD(), vault.inferenceReserve() + vault.buybackReserve());
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_fundWithdrawRoundtrip(uint96 raw, bool inferenceFirst) public {
        uint256 amount = bound(raw, 0, 1000 ether);
        _fund(amount);
        uint256 safeBefore = imd.balanceOf(safe);
        uint256 a = vault.inferenceReserve();
        uint256 b = vault.buybackReserve();
        assertEq(b, amount * 3 / 10);
        assertEq(a + b, amount);
        vm.startPrank(safe);
        if (inferenceFirst) {
            vm.expectEmit(false, false, false, true, address(vault));
            emit InferenceWithdrawn(a);
            vault.withdrawInference(a);
            assertEq(vault.buybackReserve(), b);
            vault.withdrawBuyback(b);
        } else {
            vm.expectEmit(false, false, false, true, address(vault));
            emit BuybackWithdrawn(b);
            vault.withdrawBuyback(b);
            assertEq(vault.inferenceReserve(), a);
            vault.withdrawInference(a);
        }
        vm.stopPrank();
        assertEq(imd.balanceOf(safe) - safeBefore, amount);
        assertEq(_vaultIMD(), 0);
        assertEq(vault.inferenceReserve() + vault.buybackReserve(), 0);
    }

    function test_onlySafeAndMatchingReserve() public {
        _fund(10 ether);
        address[4] memory callers = [ALICE, address(this), address(hook), address(manager)];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(LifeForceVault.Unauthorized.selector);
            vault.withdrawInference(1);
            vm.expectRevert(LifeForceVault.Unauthorized.selector);
            vault.withdrawBuyback(1);
            vm.stopPrank();
        }
        vm.startPrank(safe);
        vm.expectRevert(LifeForceVault.InvalidAmount.selector);
        vault.withdrawInference(7 ether + 1);
        vm.expectRevert(LifeForceVault.InvalidAmount.selector);
        vault.withdrawBuyback(3 ether + 1);
        vault.withdrawBuyback(3 ether);
        vm.expectRevert(LifeForceVault.InvalidAmount.selector);
        vault.withdrawBuyback(1);
        assertEq(vault.inferenceReserve(), 7 ether);
        vault.withdrawInference(7 ether);
        vm.expectRevert(LifeForceVault.InvalidAmount.selector);
        vault.withdrawInference(1);
        vm.stopPrank();
    }

    /// The Safe refusing IMD (the IMD analogue of a Safe that rejects ETH) rolls the withdrawal back.
    function test_rejectingSafeRollsBackBothWithdrawalsAndCanRetry() public {
        _fund(10 ether);
        imd.setRefuses(safe, true);
        vm.startPrank(safe);
        vm.expectRevert(LifeForceVault.TransferFailed.selector);
        vault.withdrawInference(7 ether);
        vm.expectRevert(LifeForceVault.TransferFailed.selector);
        vault.withdrawBuyback(3 ether);
        vm.stopPrank();
        assertEq(vault.inferenceReserve(), 7 ether);
        assertEq(vault.buybackReserve(), 3 ether);
        assertEq(_vaultIMD(), 10 ether);
        imd.setRefuses(safe, false);
        vm.startPrank(safe);
        vault.withdrawInference(7 ether);
        vault.withdrawBuyback(3 ether);
        vm.stopPrank();
        assertEq(_vaultIMD(), 0);
        assertEq(imd.balanceOf(safe), 10 ether);
    }

    /// A token that returns false instead of moving funds must also revert and leave reserves untouched.
    function test_falseReturningIMDRollsBackBothWithdrawals() public {
        _fund(10 ether);
        imd.setReturnFalse(true);
        vm.startPrank(safe);
        vm.expectRevert(LifeForceVault.TransferFailed.selector);
        vault.withdrawInference(7 ether);
        vm.expectRevert(LifeForceVault.TransferFailed.selector);
        vault.withdrawBuyback(3 ether);
        vm.stopPrank();
        assertEq(vault.inferenceReserve(), 7 ether);
        assertEq(vault.buybackReserve(), 3 ether);
        assertEq(_vaultIMD(), 10 ether);
        assertEq(imd.balanceOf(safe), 0);
        imd.setReturnFalse(false);
        vm.startPrank(safe);
        vault.withdrawInference(7 ether);
        vault.withdrawBuyback(3 ether);
        vm.stopPrank();
        assertEq(imd.balanceOf(safe), 10 ether);
    }

    function testFuzz_sameAndCrossWithdrawalReentryBlocked(bool inferenceFirst) public {
        _fund(10 ether);
        vm.etch(safe, address(new SafeReentryProbe(vault)).code);
        imd.setCallback(safe);
        vm.prank(safe);
        if (inferenceFirst) vault.withdrawInference(1 ether);
        else vault.withdrawBuyback(1 ether);
        SafeReentryProbe probe = SafeReentryProbe(safe);
        assertFalse(probe.inferenceOK());
        assertFalse(probe.buybackOK());
        assertEq(probe.inferenceError(), abi.encodeWithSelector(Guard.Reentrancy.selector));
        assertEq(probe.buybackError(), abi.encodeWithSelector(Guard.Reentrancy.selector));
        assertEq(_vaultIMD(), 9 ether);
        assertEq(imd.balanceOf(safe), 1 ether);
        assertEq(vault.inferenceReserve(), inferenceFirst ? 6 ether : 7 ether);
        assertEq(vault.buybackReserve(), inferenceFirst ? 3 ether : 2 ether);
    }

    function test_burnEntireBalanceToDeadWithoutIMDMovement() public {
        _fund(10 ether);
        vm.expectRevert(LifeForceVault.InvalidAmount.selector);
        vault.burn();
        token.transfer(address(vault), 123 ether);
        vm.prank(ALICE);
        token.transfer(address(vault), 7 ether);
        assertEq(vault.sovrnHeld(), 130 ether);
        vm.expectEmit(false, false, false, true, address(vault));
        emit Burned(130 ether);
        vm.prank(BOB);
        vault.burn();
        assertEq(vault.sovrnHeld(), 0);
        assertEq(token.balanceOf(token.DEAD()), 130 ether);
        assertEq(token.totalBurned(), 130 ether);
        assertEq(token.totalSupply(), 1e27);
        assertEq(_vaultIMD(), 10 ether);
        assertEq(vault.inferenceReserve(), 7 ether);
        assertEq(vault.buybackReserve(), 3 ether);
        vm.expectRevert(LifeForceVault.InvalidAmount.selector);
        vault.burn();
    }

    function test_noTokenRescueApprovalOrAlternateDestinationEvenForSafe() public {
        token.transfer(address(vault), 1 ether);
        string[6] memory signatures = [
            "transfer(address,uint256)",
            "approve(address,uint256)",
            "withdrawToken(address,uint256)",
            "rescueToken(address,uint256)",
            "burn(address)",
            "setSafe(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(safe);
            (bool ok,) = address(vault).call(abi.encodeWithSignature(signatures[i], ALICE, 1 ether));
            assertFalse(ok);
        }
        assertEq(vault.sovrnHeld(), 1 ether);
        assertEq(token.allowance(address(vault), ALICE), 0);
        assertEq(imd.allowance(address(vault), ALICE), 0);
        assertEq(imd.allowance(address(vault), safe), 0);
    }

    /// Replaces the forced-ETH test: IMD sent straight to the vault is visible (split floor 70/30) before any
    /// checkpoint, and only the Safe can take it.
    function test_unsolicitedIMDIncludedAndWithdrawableOnlyBySafe() public {
        _fund(11);
        assertTrue(imd.transfer(address(vault), 19));
        assertEq(vault.buybackReserve(), 3 + 5);
        assertEq(vault.inferenceReserve(), 8 + 14);
        _fund(3);
        assertEq(vault.inferenceReserve() + vault.buybackReserve(), 33);
        vm.prank(ALICE);
        vm.expectRevert(LifeForceVault.Unauthorized.selector);
        vault.withdrawInference(1);
        vm.prank(ALICE);
        vm.expectRevert(LifeForceVault.Unauthorized.selector);
        vault.withdrawBuyback(1);
        vm.startPrank(safe);
        // The unsolicited 19 and the later 3 are split together (22 -> 6 buyback): 3 + 6 and 8 + 16.
        assertEq(vault.buybackReserve(), 9);
        vault.withdrawInference(24);
        vault.withdrawBuyback(9);
        vm.stopPrank();
        assertEq(_vaultIMD(), 0);
        assertEq(imd.balanceOf(safe), 33);
    }

    function testFuzz_unsolicitedIMDSplitsFloor(uint96 raw) public {
        uint256 amount = bound(raw, 0, 1e30);
        assertTrue(imd.transfer(address(vault), amount));
        assertEq(vault.buybackReserve(), amount * 3000 / 10_000);
        assertEq(vault.inferenceReserve(), amount - amount * 3000 / 10_000);
    }

    function test_syncCheckpointsAndEmitsOnlyForNewIMD() public {
        // Nothing arrived: silent no-op.
        vm.recordLogs();
        vault.sync();
        assertEq(vm.getRecordedLogs().length, 0);
        // 1001 arrives: floor(1001 * 3000 / 10000) = 300 to buyback.
        assertTrue(imd.transfer(address(vault), 1001));
        vm.expectEmit(true, false, false, true, address(vault));
        emit LifeForceFunded(address(0), 1001, 701, 300);
        vm.prank(ALICE);
        vault.sync();
        assertEq(vault.inferenceReserve(), 701);
        assertEq(vault.buybackReserve(), 300);
        // Second sync with nothing new: silent, reserves unchanged.
        vm.recordLogs();
        vault.sync();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(vault.inferenceReserve(), 701);
        assertEq(vault.buybackReserve(), 300);
        // Checkpointing does not change the split for the next deposit.
        assertTrue(imd.transfer(address(vault), 9));
        vm.expectEmit(true, false, false, true, address(vault));
        emit LifeForceFunded(address(0), 9, 7, 2);
        vault.sync();
        assertEq(vault.inferenceReserve(), 708);
        assertEq(vault.buybackReserve(), 302);
    }

    function test_clampTransferFeeAndSeizedIMDShortfallReducesBuybackFirst() public {
        // A transfer fee on deposit: the vault only ever sees what really arrived.
        imd.setFeeBps(1000);
        assertTrue(imd.transfer(address(vault), 10 ether));
        imd.setFeeBps(0);
        assertEq(_vaultIMD(), 9 ether);
        assertEq(vault.inferenceReserve() + vault.buybackReserve(), 9 ether);
        vault.sync();
        assertEq(vault.inferenceReserve(), 6.3 ether);
        assertEq(vault.buybackReserve(), 2.7 ether);

        // 3 ether leave the vault by some other route: shortfall comes out of buyback first.
        vm.prank(address(vault));
        imd.transfer(BOB, 3 ether);
        assertEq(_vaultIMD(), 6 ether);
        assertEq(vault.inferenceReserve(), 6 ether);
        assertEq(vault.buybackReserve(), 0);
        assertEq(vault.inferenceReserve() + vault.buybackReserve(), _vaultIMD());

        // Smaller shortfall: buyback is only partly reduced, inference untouched.
        vm.prank(BOB);
        imd.transfer(address(vault), 2 ether);
        vault.sync(); // checkpoint 6.3 / 1.7 (balance 8 -> sums to 8)
        assertEq(vault.inferenceReserve(), 6.3 ether);
        assertEq(vault.buybackReserve(), 1.7 ether);
        vm.prank(address(vault));
        imd.transfer(BOB, 1 ether);
        assertEq(vault.inferenceReserve(), 6.3 ether);
        assertEq(vault.buybackReserve(), 0.7 ether);

        // A withdrawal up to the clamped reserve never reverts for solvency reasons.
        vm.startPrank(safe);
        vault.withdrawInference(6.3 ether);
        vault.withdrawBuyback(0.7 ether);
        vm.stopPrank();
        assertEq(_vaultIMD(), 0);
        assertEq(imd.balanceOf(safe), 7 ether);
    }

    /// @dev Audit finding 1: a permissionless sync() during a temporary shortfall must not rewrite the 70/30 split.
    function test_syncDuringShortfallDoesNotRewriteSplit() public {
        _fund(100 ether);
        assertEq(vault.inferenceReserve(), 70 ether);
        assertEq(vault.buybackReserve(), 30 ether);

        vm.prank(address(vault));
        imd.transfer(BOB, 30 ether);
        assertEq(vault.inferenceReserve(), 70 ether);
        assertEq(vault.buybackReserve(), 0);

        vm.prank(BOB);
        vault.sync(); // anyone may checkpoint while the balance is short
        assertEq(vault.inferenceReserve(), 70 ether);
        assertEq(vault.buybackReserve(), 0);

        vm.prank(BOB);
        imd.transfer(address(vault), 30 ether);
        assertEq(vault.inferenceReserve(), 70 ether);
        assertEq(vault.buybackReserve(), 30 ether);
        vault.sync();
        assertEq(vault.inferenceReserve(), 70 ether);
        assertEq(vault.buybackReserve(), 30 ether);
    }

    /// @dev Same property for a Safe withdrawal made during the shortfall: it spends only what is really there,
    ///      and the part of the checkpoint that was temporarily unbacked comes back when the IMD does.
    function test_withdrawDuringShortfallKeepsUnbackedCheckpoint() public {
        _fund(100 ether);
        vm.prank(address(vault));
        imd.transfer(BOB, 30 ether); // balance 70: views 70 / 0

        vm.startPrank(safe);
        vm.expectRevert(LifeForceVault.InvalidAmount.selector);
        vault.withdrawBuyback(1);
        vault.withdrawInference(20 ether);
        vm.stopPrank();
        assertEq(vault.inferenceReserve(), 50 ether);
        assertEq(vault.buybackReserve(), 0);
        assertEq(vault.inferenceReserve() + vault.buybackReserve(), _vaultIMD());

        vm.prank(BOB);
        imd.transfer(address(vault), 30 ether); // balance 80
        assertEq(vault.inferenceReserve(), 50 ether);
        assertEq(vault.buybackReserve(), 30 ether);
        assertEq(vault.inferenceReserve() + vault.buybackReserve(), _vaultIMD());
    }

    /// @dev Audit finding 7 (vault side): the vault's views and withdrawals depend on IMD.balanceOf and revert
    ///      with TransferFailed while it is unavailable; nothing is lost or mis-accounted afterwards.
    function test_balanceOfRevertingBlocksViewsAndWithdrawalsOnly() public {
        _fund(10 ether);
        vm.mockCallRevert(IMD_ADDR, abi.encodeWithSignature("balanceOf(address)", address(vault)), "paused");
        vm.expectRevert(LifeForceVault.TransferFailed.selector);
        vault.inferenceReserve();
        vm.prank(safe);
        vm.expectRevert(LifeForceVault.TransferFailed.selector);
        vault.withdrawInference(1);
        vm.clearMockedCalls();
        assertEq(vault.inferenceReserve(), 7 ether);
        assertEq(vault.buybackReserve(), 3 ether);
    }

    function testFuzz_clampNeverExceedsBalance(uint96 depositRaw, uint96 removeRaw, bool inferenceFirst) public {
        uint256 deposit = bound(depositRaw, 0, 1000 ether);
        _fund(deposit);
        uint256 removed = bound(removeRaw, 0, deposit);
        vm.prank(address(vault));
        imd.transfer(BOB, removed);
        uint256 balance = _vaultIMD();
        uint256 a = vault.inferenceReserve();
        uint256 b = vault.buybackReserve();
        assertEq(a + b, balance);
        // Inference has priority: buyback absorbs the loss first.
        uint256 inf0 = deposit - deposit * 3 / 10;
        assertEq(a, balance < inf0 ? balance : inf0);
        vm.startPrank(safe);
        if (inferenceFirst) {
            vault.withdrawInference(a);
            vault.withdrawBuyback(b);
        } else {
            vault.withdrawBuyback(b);
            vault.withdrawInference(a);
        }
        vm.stopPrank();
        assertEq(_vaultIMD(), 0);
        assertEq(imd.balanceOf(safe), balance);
    }

    function test_plainETHToVaultReverts() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1}("");
        assertFalse(ok);
        (ok,) = address(vault).call{value: 1}(abi.encodeWithSignature("sync()"));
        assertFalse(ok);
        assertEq(address(vault).balance, 0);
    }

    function test_constructorDoesNotRequireIMDCode() public {
        PoolManager freshManager = new PoolManager(address(this));
        SovrnToken freshToken = new SovrnToken();
        // Sanity: deployable with everything present.
        LifeForceVault ok = new LifeForceVault(freshManager, freshToken, address(this));
        assertEq(ok.imd(), IMD_ADDR);
        // The admission floor deploys without IMD code present, so the constructor does not check for it.
        vm.etch(IMD_ADDR, "");
        assertEq(new LifeForceVault(freshManager, freshToken, address(this)).imd(), IMD_ADDR);
    }

    function test_constructorRevertsForMissingManagerTokenOrHook() public {
        PoolManager freshManager = new PoolManager(address(this));
        SovrnToken freshToken = new SovrnToken();
        vm.expectRevert(LifeForceVault.Unauthorized.selector);
        new LifeForceVault(IPoolManager(address(0xdead01)), freshToken, address(this));
        vm.expectRevert(LifeForceVault.Unauthorized.selector);
        new LifeForceVault(freshManager, SovrnToken(address(0xdead02)), address(this));
        vm.expectRevert(LifeForceVault.Unauthorized.selector);
        new LifeForceVault(freshManager, freshToken, address(0));
    }
}

/// @dev Same suite with IMD as currency1 (the token sits at a lower address).
contract VaultTestImdHigh is VaultTest {
    function _imdIsCurrency0() internal view override returns (bool) {
        return false;
    }
}
