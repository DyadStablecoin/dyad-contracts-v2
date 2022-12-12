// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "ds-test/test.sol";

import {IdNFT} from "../../src/interfaces/IdNFT.sol";
import {dNFT} from "../../src/dNFT.sol";
import {PoolLibrary} from "../../src/PoolLibrary.sol";
import {OracleMock} from "./../Oracle.t.sol";
import "../../src/dyad.sol";
import "../../src/pool.sol";
import {Deployment} from "../../script/Deployment.sol";
import {Stake} from "../../src/stake/Stake.sol";

uint constant DEPOSIT_MINIMUM = 5000000000000000000000;
uint constant ORACLE_PRICE = 120000000000; // $1.2k

interface CheatCodes {
   function addr(uint256) external returns (address);
}

contract StakeTest is Test,Deployment {
  using stdStorage for StdStorage;

  OracleMock public oracle;
  IdNFT public dnft;
  DYAD public dyad;
  Pool public pool;
  Stake public stake;
  CheatCodes cheats = CheatCodes(HEVM_ADDRESS);
  address public addr1;

  function setOraclePrice(uint price) public {
    vm.store(address(oracle), bytes32(uint(0)), bytes32(price)); 
  }

  function setUp() public {
    oracle = new OracleMock();

    setOraclePrice(ORACLE_PRICE);

    address _dnft; address _pool; address _dyad;
    (_dnft, _pool, _dyad) = new Deployment().deploy(address(oracle), DEPOSIT_MINIMUM, true);

    dyad = DYAD(_dyad);
    dnft = IdNFT(_dnft);
    pool = Pool(_pool);
    stake = new Stake(_dnft, _dyad);

    addr1 = cheats.addr(1);
  }

  function testStake() public {
    uint id = dnft.mintNft{value: 5 ether}(addr1);
    vm.prank(addr1);
    dnft.approve(address(stake), id);

    vm.prank(addr1);
    dyad.approve(address(dnft), 200);

    vm.prank(addr1);
    dnft.withdraw(id, 200);

    vm.prank(addr1);
    stake.stake(id);

    vm.prank(addr1);
    dyad.approve(address(stake), 200);

    console.log(address(dyad));
    vm.prank(addr1);
    stake.redeem(id, 200);

    // vm.prank(addr1);
    // stake.unstake(id);
  }
}
