// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PrepareLaunch} from "../script/PrepareLaunch.s.sol";
import {SovrnToken} from "../src/SovrnToken.sol";
import {SovrnHook} from "../src/SovrnHook.sol";
import {LifeForceVault} from "../src/LifeForceVault.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {MockIMD} from "./mocks/MockERC20.sol";

contract LaunchFactoryHarness {
    function deployToken() external returns (SovrnToken) {
        return new SovrnToken();
    }

    /// @dev Bubbles the constructor's revert data so tests can assert the exact error.
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), salt) }
        if (deployed == address(0)) {
            assembly ("memory-safe") {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function initialize(IPoolManager manager, PoolKey memory key, uint160 price) external {
        manager.initialize(key, price);
    }
}

contract LaunchTest is Test {
    using StateLibrary for IPoolManager;
    uint160 private constant INITIAL_PRICE = 792281625142643375935439503360000;
    address private constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;

    struct Launch {
        PoolManager manager;
        LaunchFactoryHarness factory;
        SovrnToken token;
        bytes code;
        bytes32 salt;
        address expected;
    }

    function _placeIMD() private {
        vm.chainId(4663);
        deployCodeTo("MockERC20.sol:MockIMD", abi.encode(uint256(1e33)), IMD);
    }

    /// @dev The token comes from a CREATE, so keep deploying until its address lands on the wanted side of IMD.
    function _prepare(bool tokenAboveIMD) private returns (Launch memory l) {
        _placeIMD();
        l.manager = new PoolManager(address(this));
        l.factory = new LaunchFactoryHarness();
        l.token = l.factory.deployToken();
        for (uint256 i; (address(l.token) > IMD) != tokenAboveIMD; ++i) {
            require(i < 64, "no token address on the wanted side");
            l.token = l.factory.deployToken();
        }
        PrepareLaunch p = new PrepareLaunch();
        l.code = p.initCode(l.manager, l.token, address(l.factory));
        bool found;
        (found, l.salt, l.expected) = p.mine(address(l.factory), keccak256(l.code), 0, 200000);
        assertTrue(found);
        assertTrue(HookFlags.matches(l.expected, HookFlags.SOVRN_FLAGS));
    }

    function _sortedKey(SovrnToken token, address hook) private pure returns (PoolKey memory) {
        (address a, address b) = IMD < address(token) ? (IMD, address(token)) : (address(token), IMD);
        return PoolKey(Currency.wrap(a), Currency.wrap(b), 12500, 60, IHooks(hook));
    }

    function _launch(bool tokenAboveIMD) private {
        Launch memory l = _prepare(tokenAboveIMD);
        SovrnHook hook = SovrnHook(payable(l.factory.deploy(l.code, l.salt)));
        assertEq(address(hook), l.expected);
        assertEq(hook.imdIsCurrency0(), tokenAboveIMD);
        assertEq(l.token.balanceOf(address(l.factory)), 1e27);
        assertGt(address(hook.vault()).code.length, 0);
        assertEq(hook.vault().hook(), l.expected);
        assertEq(address(hook.vault().token()), address(l.token));
        assertEq(hook.vault().imd(), IMD);
        PoolKey memory key = _sortedKey(l.token, l.expected);
        // The pool pairs IMD with SVO, never anything else, and the hook reports exactly this key once opened.
        assertEq(Currency.unwrap(key.currency0) < Currency.unwrap(key.currency1) ? 1 : 0, 1);
        vm.expectRevert();
        l.manager.initialize(key, INITIAL_PRICE);
        // Wrong pairing (native ETH) is refused by the hook.
        PoolKey memory eth = PoolKey(Currency.wrap(address(0)), key.currency1, 12500, 60, IHooks(l.expected));
        vm.expectRevert();
        l.factory.initialize(l.manager, eth, INITIAL_PRICE);
        // Price is written for "IMD is currency0"; mirror it when IMD is currency1.
        uint160 price = tokenAboveIMD ? INITIAL_PRICE : uint160((uint256(1) << 192) / INITIAL_PRICE);
        l.factory.initialize(l.manager, key, price);
        (uint160 actualPrice,,,) = IPoolManager(address(l.manager)).getSlot0(key.toId());
        assertEq(actualPrice, price);
        uint256 rootRatio = uint256(actualPrice) / (1 << 96);
        if (tokenAboveIMD) {
            assertEq(rootRatio * rootRatio, 100_000_000);
            assertEq(l.token.totalSupply() / (rootRatio * rootRatio), 10 ether);
        } else {
            // currency1 is IMD: the inverse price, 1e-8 IMD per SVO, floors to a zero root ratio.
            assertEq(rootRatio, 0);
        }
        assertTrue(hook.initialized());
        assertEq(hook.launchFeeNow(), 0.5e18);
        assertEq(Currency.unwrap(hook.poolKey().currency0), Currency.unwrap(key.currency0));
        assertEq(Currency.unwrap(hook.poolKey().currency1), Currency.unwrap(key.currency1));
        vm.expectRevert();
        l.factory.initialize(l.manager, key, price);
        assertLe(l.expected.code.length, 24576);
        assertLe(address(hook.vault()).code.length, 24576);
        assertLe(l.code.length, 49152);
    }

    function test_realCreate2DeploymentInitializesAllContracts_tokenAboveIMD() public {
        _launch(true);
    }

    function test_realCreate2DeploymentInitializesAllContracts_tokenBelowIMD() public {
        _launch(false);
    }

    /// @dev The admission floor deploys the attested code on a plain local EVM with no chain id set and no code at
    ///      IMD, so the constructors must not gate on either. The factory only launches on the right chain.
    function test_deploymentNeedsNeitherChainIdNorIMDCode() public {
        Launch memory l = _prepare(false);
        uint256[3] memory chains = [uint256(1), 31337, 4664];
        for (uint256 i; i < chains.length; ++i) {
            uint256 snap = vm.snapshotState();
            vm.chainId(chains[i]);
            assertEq(l.factory.deploy(l.code, l.salt), l.expected);
            vm.revertToState(snap);
        }
        vm.etch(IMD, "");
        vm.chainId(31337);
        SovrnHook hook = SovrnHook(payable(l.factory.deploy(l.code, l.salt)));
        assertEq(address(hook), l.expected);
        assertGt(address(hook.vault()).code.length, 0);
    }

    function test_deploymentWhereTokenIsIMDReverts() public {
        _placeIMD();
        PoolManager manager = new PoolManager(address(this));
        LaunchFactoryHarness factory = new LaunchFactoryHarness();
        PrepareLaunch p = new PrepareLaunch();
        bytes memory code = p.initCode(manager, SovrnToken(IMD), address(factory));
        (bool found, bytes32 salt,) = p.mine(address(factory), keccak256(code), 0, 200000);
        assertTrue(found);
        vm.expectRevert(SovrnHook.Unauthorized.selector);
        factory.deploy(code, salt);
    }

    function test_deploymentGas() public {
        Launch memory l = _prepare(true);
        LaunchFactoryHarness factory = new LaunchFactoryHarness();
        uint256 g = gasleft();
        factory.deployToken();
        uint256 tokenGas = g - gasleft();
        g = gasleft();
        l.factory.deploy(l.code, l.salt);
        uint256 hookGas = g - gasleft();
        emit log_named_uint("gas: token deployment (CREATE via factory)", tokenGas);
        emit log_named_uint("gas: hook + vault deployment (CREATE2 via factory)", hookGas);
        emit log_named_uint("hook initcode bytes", l.code.length);
        emit log_named_uint("hook runtime bytes", l.expected.code.length);
        assertLt(hookGas, 3_000_000);
        assertLt(tokenGas, 1_000_000);
    }

    function test_codeSizes() public {
        Launch memory l = _prepare(true);
        SovrnHook hook = SovrnHook(payable(l.factory.deploy(l.code, l.salt)));
        emit log_named_uint("hook runtime", address(hook).code.length);
        emit log_named_uint("vault runtime", address(hook.vault()).code.length);
        assertLe(address(hook).code.length, 24576);
        assertLe(address(hook.vault()).code.length, 24576);
        assertLe(l.code.length, 49152);
    }
}
