Description
RealWorld Fei-Rari 실기 문제

문제 설명
Fei-Rari 배포 환경에서 특정 파일을 아래와 같이 변경했습니다. 50 ETH를 모으세요

'''
// CEther.sol (0xd77E28A1b9a9cFe1fc2EEE70E391C05d25853cbF)
function doTransferOut(address payable to, uint amount) internal {
    // Send the Ether and revert on failure
    to.transfer(amount);
}


// Dai.sol (0x6b175474e89094c44da98b954eedeac495271d0f)
function transferFrom(address src, address dst, uint wad)
    public returns (bool)
{
    require(balanceOf[src] >= wad, ""Dai/insufficient-balance"");
    if (src != msg.sender && allowance[src][msg.sender] != uint(-1)) {
        require(allowance[src][msg.sender] >= wad, ""Dai/insufficient-allowance"");
        allowance[src][msg.sender] = sub(allowance[src][msg.sender], wad);
    }
    balanceOf[src] = sub(balanceOf[src], wad);
    balanceOf[dst] = add(balanceOf[dst], wad);
    emit Transfer(src, dst, wad);
    address(dst).call(hex"41424344");
    return true;
}
'''



Fei Rari (50 ETH)
RPC: https://REDACTED.example.invalid/ca17ed3a-9731-47ca-9e09-8bd01ad67197/rpc/4gi_akali:575d580ce56856c4751f2afb8daf13cc21c4eefd48958f1734e36a44d5f23734
Reset: https://REDACTED.example.invalid/ca17ed3a-9731-47ca-9e09-8bd01ad67197/rpc/4gi_akali:575d580ce56856c4751f2afb8daf13cc21c4eefd48958f1734e36a44d5f23734
Contract Address: https://REDACTED.example.invalid/ca17ed3a-9731-47ca-9e09-8bd01ad67197/contract_address/4gi_akali:575d580ce56856c4751f2afb8daf13cc21c4eefd48958f1734e36a44d5f23734
Flag: https://REDACTED.example.invalid/ca17ed3a-9731-47ca-9e09-8bd01ad67197/flag/4gi_akali:575d580ce56856c4751f2afb8daf13cc21c4eefd48958f1734e36a44d5f23734