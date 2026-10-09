// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SovrnToken} from "./SovrnToken.sol";
import {LifeForceVault} from "./LifeForceVault.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Immutable IMD-fee hook for the SVO/IMD pool on Robinhood Chain. Every fee is paid in IMD (an ERC-20)
///         and is based on the actual AMM IMD delta. The pool's currency order is fixed by the two addresses.
contract SovrnHook {
    uint256 public constant WAD = 1e18;
    uint256 public constant NORMAL_FEE = 0.035e18;
    uint256 public constant DECAY = 60 minutes;
    /// @notice IMD on Robinhood Chain (18 decimals). The only fee currency.
    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    IPoolManager public immutable poolManager;
    SovrnToken public immutable token;
    address public immutable factory;
    /// @notice True when IMD is the pool's currency0 (its address is lower than the token's).
    bool public immutable imdIsCurrency0;
    LifeForceVault public immutable vault;
    uint256 public openedAt;
    bool public initialized;
    int24 public tickSpacing;
    bool private busy;
    bool private redeeming;
    uint256 private quotedFee;
    int128 private quotedIMD;
    uint256 public claimFees;
    event PoolOpened(uint256 timestamp);
    event FeePaid(address indexed router, bool indexed buy, uint256 grossIMD, uint256 fee, bool asClaim);
    event ClaimsRedeemed(uint256 amount);
    error Unauthorized();
    error LiquidityLocked();
    error WrongPool();
    error Busy();
    error InvalidAmount();
    error QuoteResult(int128 imdDelta);
    error QuoteMismatch();

    constructor(IPoolManager manager_, SovrnToken token_, address factory_) {
        if (
            address(manager_).code.length == 0 || address(token_).code.length == 0 || address(token_) == IMD
                || factory_ == address(0)
        ) revert Unauthorized();
        poolManager = manager_;
        token = token_;
        factory = factory_;
        imdIsCurrency0 = IMD < address(token_);
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        vault = new LifeForceVault(manager_, token_, address(this));
    }
    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }
    modifier idle() {
        if (busy) revert Busy();
        busy = true;
        _;
        busy = false;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeAddLiquidity = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(_currency0(), _currency1(), 12_500, tickSpacing, IHooks(address(this)));
    }

    function _currency0() private view returns (Currency) {
        return Currency.wrap(imdIsCurrency0 ? IMD : address(token));
    }

    function _currency1() private view returns (Currency) {
        return Currency.wrap(imdIsCurrency0 ? address(token) : IMD);
    }

    /// @dev The IMD leg of a swap delta, whichever currency slot IMD occupies.
    function _imdAmount(BalanceDelta delta) private view returns (int128) {
        return imdIsCurrency0 ? delta.amount0() : delta.amount1();
    }

    function _checkPool(PoolKey calldata key) private view {
        if (
            !initialized || Currency.unwrap(key.currency0) != Currency.unwrap(_currency0())
                || Currency.unwrap(key.currency1) != Currency.unwrap(_currency1()) || key.fee != 12_500
                || key.tickSpacing != tickSpacing || address(key.hooks) != address(this)
        ) revert WrongPool();
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyManager returns (bytes4) {
        if (
            initialized || sender != factory || Currency.unwrap(key.currency0) != Currency.unwrap(_currency0())
                || Currency.unwrap(key.currency1) != Currency.unwrap(_currency1()) || key.fee != 12_500
                || key.tickSpacing <= 0 || address(key.hooks) != address(this)
        ) revert WrongPool();
        initialized = true;
        tickSpacing = key.tickSpacing;
        openedAt = block.timestamp;
        emit PoolOpened(block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice During the opening decay only the launch factory may add liquidity (plus anyone in the pool's opening
    ///         block, so an atomic seeding transaction works whichever contract performs it). An IMD-only range
    ///         placed beside the price would otherwise turn IMD into SVO through sell flow and skip the buy fee.
    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        onlyManager
        returns (bytes4)
    {
        _checkPool(key);
        if (sender != factory && block.timestamp != openedAt && block.timestamp < openedAt + DECAY) {
            revert LiquidityLocked();
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice WAD rate; 0.5e18 at opening, 0.035e18 at 60 minutes. Sells always pay NORMAL_FEE.
    function launchFeeNow() public view returns (uint256) {
        if (!initialized) return 0.5e18;
        uint256 elapsed = block.timestamp - openedAt;
        return elapsed >= DECAY ? NORMAL_FEE : NORMAL_FEE + 0.465e18 * (DECAY - elapsed) / DECAY;
    }

    function decayMinutesLeft() external view returns (uint256) {
        if (!initialized) return 60;
        uint256 elapsed = block.timestamp - openedAt;
        return elapsed >= DECAY ? 0 : (DECAY - elapsed + 59) / 60;
    }

    /// @dev IMD specified: quote with a reverting self-call, then return only the actual IMD fee.
    ///      No speculative state survives the quote. This supports price-limit partial fills without
    ///      charging a fee on unused input or unmet output. All other modes need no quote.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        if (busy) revert Busy();
        if (
            params.amountSpecified == 0 || params.amountSpecified > type(int128).max
                || params.amountSpecified < -int256(type(int128).max)
        ) revert InvalidAmount();
        busy = true;
        uint256 fee;
        // A BUY pays IMD in (zeroForOne exactly when IMD is currency0); a SELL pays SVO in.
        bool buy = params.zeroForOne == imdIsCurrency0;
        bool specifiedIMD = buy == (params.amountSpecified < 0);
        if (specifiedIMD) {
            uint256 rate = buy ? launchFeeNow() : NORMAL_FEE;
            SwapParams memory quoteParams = params;
            uint256 requested = uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified);
            if (buy) {
                fee = requested * rate / WAD;
                quoteParams.amountSpecified = -int256(requested - fee);
            } else {
                uint256 gross = requested * WAD / (WAD - rate);
                if (gross > uint256(uint128(type(int128).max))) revert InvalidAmount();
                quoteParams.amountSpecified = int256(gross);
            }
            int128 imdDelta = _quote(key, quoteParams);
            uint256 actual = _abs(imdDelta);
            if (buy) {
                if (actual != uint256(-quoteParams.amountSpecified)) fee = actual * rate / (WAD - rate);
            } else {
                fee = actual * rate / WAD;
            }
            quotedIMD = imdDelta;
            quotedFee = fee;
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_int128(fee), 0), 0);
    }

    function _quote(PoolKey calldata key, SwapParams memory params) private returns (int128 value) {
        try this.quoteIMD(key, params) {
            revert QuoteMismatch();
        } catch (bytes memory reason) {
            if (reason.length != 36 || bytes4(reason) != QuoteResult.selector) {
                assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
            }
            assembly ("memory-safe") { value := mload(add(reason, 36)) }
        }
    }

    /// @dev Only this contract can quote. PoolManager skips callbacks for its own hook as sender.
    ///      Always reverts, rolling back the nested swap, its accounting, protocol fees and logs.
    function quoteIMD(PoolKey calldata key, SwapParams calldata params) external {
        if (msg.sender != address(this) || !busy) revert Unauthorized();
        BalanceDelta result = poolManager.swap(key, params, "");
        revert QuoteResult(_imdAmount(result));
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyManager returns (bytes4, int128) {
        _checkPool(key);
        if (!busy) revert Unauthorized();
        bool buy = params.zeroForOne == imdIsCurrency0;
        bool specifiedIMD = buy == (params.amountSpecified < 0);
        int128 imdDelta = _imdAmount(delta);
        uint256 actual = _abs(imdDelta);
        uint256 rate = buy ? launchFeeNow() : NORMAL_FEE;
        uint256 fee;
        if (specifiedIMD) {
            if (imdDelta != quotedIMD) revert QuoteMismatch();
            fee = quotedFee;
            delete quotedFee;
            delete quotedIMD;
        } else {
            fee = buy ? actual * rate / (WAD - rate) : actual * rate / WAD;
        }
        uint256 gross = buy ? actual + fee : actual;
        bool asClaim;
        if (fee != 0) {
            // The balance is only read when there is a fee to take, so a zero-fee swap never depends on it.
            asClaim = _imdBalanceOf(address(poolManager)) < fee;
            if (asClaim) {
                poolManager.mint(address(this), CurrencyLibrary.toId(Currency.wrap(IMD)), fee);
                claimFees += fee;
            } else {
                poolManager.take(Currency.wrap(IMD), address(vault), fee);
            }
        }
        emit FeePaid(sender, buy, gross, fee, asClaim);
        busy = false;
        return (IHooks.afterSwap.selector, specifiedIMD ? int128(0) : _int128(fee));
    }

    function _abs(int128 value) private pure returns (uint256) {
        return uint256(value < 0 ? -int256(value) : int256(value));
    }

    function _int128(uint256 value) private pure returns (int128) {
        if (value > uint256(uint128(type(int128).max))) revert InvalidAmount();
        return int128(int256(value));
    }

    /// @notice Anyone may redeem all fallback IMD claims to the immutable vault after settlement.
    function redeemFees() external idle {
        uint256 amount = claimFees;
        if (amount == 0) return;
        claimFees = 0;
        redeeming = true;
        poolManager.unlock(abi.encode(amount));
        redeeming = false;
    }

    function unlockCallback(bytes calldata data) external onlyManager returns (bytes memory) {
        if (!redeeming || !busy) revert Unauthorized();
        uint256 amount = abi.decode(data, (uint256));
        poolManager.burn(address(this), CurrencyLibrary.toId(Currency.wrap(IMD)), amount);
        poolManager.take(Currency.wrap(IMD), address(vault), amount);
        emit ClaimsRedeemed(amount);
        return "";
    }

    function _imdBalanceOf(address who) private view returns (uint256) {
        (bool ok, bytes memory data) = IMD.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        if (!ok || data.length < 32) revert InvalidAmount();
        return abi.decode(data, (uint256));
    }
}
