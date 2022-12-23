// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import {IAggregatorV3} from "../interfaces/AggregatorV3Interface.sol";
import {DYAD} from "./Dyad.sol";
import {Pool} from "./Pool.sol";
import {PoolLibrary} from "../libraries/PoolLibrary.sol";

struct Nft {
  uint withdrawn; // dyad withdrawn from the pool deposit
  int deposit;    // dyad balance in pool
  uint xp;        // always positive, always inflationary
  bool isLiquidatable;
}

// A convenient way to store the ouptput of the `calcMultis` function
struct Multis {
  // Holds two different sort of values depending on wheather the 
  // protocoll is in BURNING or MINTING mode.
  //   Mode.MINTING: xp mulit * deposit multi
  //   Mode.BURNING: xp mulit * mintAvg  
  uint[] multiProducts;

  uint   multiProductsSum; // sum of the elements in `multiProducts`
  uint[] xpMultis;         
}

contract dNFT is ERC721Enumerable, ERC721Burnable {
  uint public lastEthPrice;

  // maximum number of nfts that can exist at one point in time
  uint public MAX_SUPPLY;

  // 150% in basis points
  uint constant public MIN_COLLATERATION_RATIO = 15000; 

  // stores the number of nfts that have been minted. we need this in order to
  // generate a new id for the next minted nft.
  uint public numberOfMints;

  // deposit minimum required to mint a new dnft
  // should be a constant, but then some of the tests do not work because they 
  // depend on manipulating this value.
  // as this is only set in the constructor, it should not be a problem.
  uint public DEPOSIT_MINIMUM;

  // here we store the min/max value of xp over every dNFT,
  // which allows us to do a normalization, without iterating over
  // all of them to find the min/max value.
  uint public MIN_XP; uint public MAX_XP;

  DYAD public dyad;
  Pool public pool;
  IAggregatorV3 internal oracle;

  // mapping from nft id to nft 
  mapping(uint => Nft) public idToNft;

  // when syncing, the protocol can be in two states:
  //   BURNING: if the price of eth went down
  //   MINTING: if the price of eth went up
  enum Mode{ BURNING, MINTING }

  event NftMinted    (address indexed to, uint indexed id);
  event DyadMinted   (address indexed to, uint indexed id, uint amount);
  event DyadWithdrawn(address indexed to, uint indexed id, uint amount);
  event DyadDeposited(address indexed to, uint indexed id, uint amount);
  event DyadRedeemed (address indexed to, uint indexed id, uint amount);
  event Synced       (uint newEthPrice);
  event NftClaimed   (uint indexed id, address indexed from, address indexed to);

  modifier onlyNFTOwner(uint id) {
    require(this.ownerOf(id) == msg.sender, "dNFT: Only callable by NFT owner");
    _;
  }
  // Require CR >= `MIN_COLLATERATION_RATIO`, after removing `amount`
  modifier overCR(uint amount) {
    uint cr              = MIN_COLLATERATION_RATIO;
    uint updatedBalance  = dyad.balanceOf(address(this)) - amount;
    uint totalWithdrawn  = dyad.totalSupply() - updatedBalance;
    if (totalWithdrawn != 0) { cr =  updatedBalance*10000 / totalWithdrawn; }     
    require(cr >= MIN_COLLATERATION_RATIO, "CR is under 150%"); 
    _;
  }

  constructor(address _dyad,
              uint    _depositMinimum,
              uint    _maxSupply, 
              address _oracle, 
              address[] memory insiders) ERC721("DYAD NFT", "dNFT") {
    dyad            = DYAD(_dyad);
    DEPOSIT_MINIMUM = _depositMinimum;
    MAX_SUPPLY      = _maxSupply;
    oracle          = IAggregatorV3(_oracle);
    lastEthPrice    = uint(getNewEthPrice());
    MIN_XP = _maxSupply;
    MAX_XP = _maxSupply * 2;

    for (uint i = 0; i < insiders.length; i++) { _mintNft(insiders[i]); }
  }

  // Set pool once
  function setPool(address newPool) public {
    require(address(pool) == address(0),"dNFT: Pool is already set");
    pool = Pool(newPool);
  }

  function getNewEthPrice() internal view returns (int newEthPrice) {
    ( , newEthPrice, , , ) = oracle.latestRoundData();
  }

  // The following functions are overrides required by Solidity.
  function _beforeTokenTransfer(address from,
                                address to,
                                uint256 tokenId,
                                uint256 batchSize)
      internal override(ERC721, ERC721Enumerable)
  { super._beforeTokenTransfer(from, to, tokenId, batchSize); }

  // The following functions are overrides required by Solidity.
  function supportsInterface(bytes4 interfaceId)
      public
      view
      override(ERC721, ERC721Enumerable)
      returns (bool)
  { return super.supportsInterface(interfaceId); }

  // Mint new dNFT to `to` with a deposit of atleast `DEPOSIT_MINIMUM`
  function mintNft(address to) external payable returns (uint) {
    uint id = _mintNft(to);
    _mintDyad(id, DEPOSIT_MINIMUM);
    uint xp = idToNft[id].xp;
    if (xp < MIN_XP) { MIN_XP = xp; } // could be new global xp min
    return id;
  }

  // Mint new nft to `to` with the same xp and withdrawn amount as `nft`
  function mintCopy(
      address to,
      Nft memory nft
  ) public payable returns (uint) { // TODO: refactor to internal!
      uint id = _mintNft(to);
      Nft storage newNft = idToNft[id];
      uint minDeposit = 0;
      if (nft.deposit < 0) { minDeposit = uint(-nft.deposit); }
      uint amount = _mintDyad(id, minDeposit);
      newNft.deposit   = int(amount) + nft.deposit;
      newNft.xp        = nft.xp;
      newNft.withdrawn = nft.withdrawn;
      return id;
  }

  // Mint new dNFT to `to`
  function _mintNft(address to) private returns (uint id) {
    require(totalSupply() < MAX_SUPPLY, "Max supply reached");
    id = numberOfMints;
    numberOfMints += 1;
    _mint(to, id); 
    Nft storage nft = idToNft[id];
    nft.xp = (MAX_SUPPLY*2) - (totalSupply()-1); // break xp symmetry
    emit NftMinted(to, id);
  }

  // Mint and deposit DYAD into dNFT
  function mintDyad(uint id) payable public onlyNFTOwner(id) returns (uint amount) {
      amount = _mintDyad(id, 0);
  }

  // Mint at least `minAmount` of DYAD to dNFT 
  function _mintDyad(
      uint id,
      uint minAmount
  ) private returns (uint) {
      require(msg.value > 0, "dNFT: msg.value == 0");
      uint newDyad = uint(getNewEthPrice()) * msg.value/100000000;
      require(newDyad >= minAmount, "Pool: newDyad < minAmount");
      dyad.mint(address(this), newDyad);
      idToNft[id].deposit += int(newDyad);
      emit DyadMinted(msg.sender, id, newDyad);
      return newDyad;
  }

  // Withdraw `amount` of DYAD from dNFT
  function withdraw(
      uint id,
      uint amount
  ) external onlyNFTOwner(id) overCR(amount) returns (uint) {
      require(amount > 0, "dNFT: Withdrawl == 0");
      Nft storage nft = idToNft[id];
      uint newWithdrawn = nft.withdrawn + amount;
      uint averageTVL   = dyad.balanceOf(address(this)) / totalSupply();
      require(newWithdrawn <= averageTVL,  "dNFT: New Withdrawl > average TVL");
      require(int(amount)  <= nft.deposit, "dNFT: Withdrawl     > deposit");
      nft.withdrawn  = newWithdrawn;
      nft.deposit   -= int(amount);
      dyad.transfer(msg.sender, amount);
      emit DyadWithdrawn(msg.sender, id, amount);
      return amount;
  }

  // Deposit `amount` of DYAD into dNFT
  function deposit(
      uint id, 
      uint amount
  ) external returns (uint) {
      require(amount > 0, "dNFT: Deposit == 0");
      Nft storage nft = idToNft[id];
      require(amount <= nft.withdrawn, "dNFT: Deposit > withdrawn");
      nft.deposit   += int(amount);
      nft.withdrawn -= amount;
      dyad.transferFrom(msg.sender, address(this), amount);
      emit DyadDeposited(msg.sender, id, amount);
      return amount;
  }

  // Redeem `amount` of DYAD for ETH from dNFT
  function redeem(
      uint id,
      uint amount
  ) external onlyNFTOwner(id) returns (uint usdInEth) {
      require(amount > 0, "dNFT: Amount to redeem == 0");
      Nft storage nft = idToNft[id];
      require(amount <= nft.withdrawn, "dNFT: Amount to redeem > withdrawn");
      nft.withdrawn -= amount;
      dyad.burn(amount);
      uint eth = amount*100000000 / lastEthPrice;
      payable(msg.sender).transfer(eth);
      emit DyadRedeemed(msg.sender, id, amount);
      return usdInEth;
  }

  // Move `amount` `from` one dNFT deposit `to` another dNFT deposit
  function moveDeposit(
      uint _from,
      uint _to,
      uint amount
  ) external onlyNFTOwner(_from) returns (uint) {
      require(amount > 0, "dNFT: Deposit == 0");
      Nft storage from = idToNft[_from];
      require(int(amount) <= from.deposit, "dNFT: Amount to move > deposit");
      Nft storage to   = idToNft[_to];
      from.deposit    -= int(amount);
      to.deposit      += int(amount);
      return amount;
  }

  // Liquidate dNFT by burning it and minting a new copy to `to`
  function liquidate(
      uint id,
      address to
  ) external payable returns (uint) {
      Nft memory nft = idToNft[id];
      require(nft.isLiquidatable, "dNFT: NFT is not liquidatable");
      emit NftClaimed(id, ownerOf(id), to); 
      _burn(id); 
      return mintCopy(to, nft);
  }

  // The "heart" of the protocol.
  // - Gets the latest eth price and determines if new dyad should be minted or
  //   old dyad should be burned to keep the peg.
  // - Updates each dnft metadata to reflect its updated xp, withdrawn and 
  //   deposit.
  // - To incentivize nft holders to call this method, there is a xp boost to 
  //   the first nft of the owner calling it.
  // NOTE: check out this google sheet to get a better overview of the equations:
  // https://docs.google.com/spreadsheets/d/1pegDYo8hrOQZ7yZY428F_aQ_mCvK0d701mygZy-P04o/edit#gid=0
  function sync() public returns (uint) {
    uint newEthPrice = uint(getNewEthPrice());
    // determine the mode we are in
    Mode mode = newEthPrice > lastEthPrice ? Mode.MINTING 
                                           : Mode.BURNING;
 
    // stores the eth price change in basis points
    uint ethChange = newEthPrice*10000/lastEthPrice;
    // we have to do this to get the percentage in basis points
    mode == Mode.BURNING ? ethChange  = 10000 - ethChange 
                         : ethChange -= 10000;

    // the amount of dyad to burn/mint
    uint dyadDelta = updateNFTs(ethChange, mode);

    mode == Mode.MINTING ? dyad.mint(address(this), dyadDelta) 
                         : dyad.burn(dyadDelta);

    lastEthPrice = newEthPrice;
    emit Synced(newEthPrice);
    return dyadDelta;
  }

  /// @param ethChange  Eth price change in basis points
  /// @param mode Is the change negative or positive
  /// @return dyadDelta The amount of dyad to mint or burn
  function updateNFTs(uint ethChange, Mode mode) private returns (uint) {
    // we boost the nft of the user calling this function with additional
    // xp, but only once! If boosted was used already, it can not be used again.
    bool isBoosted = false;

    // the amount to mint/burn to keep the peg
    uint dyadDelta = PoolLibrary.percentageOf(dyad.totalSupply(), ethChange);

    Multis memory multis = calcMultis(mode);

    // we use these to keep track of the max/min xp values for this sync, 
    // so we can save them in storage to be used in the next sync.
    uint minXp = type(uint256).max;
    uint maxXp = MAX_XP;

    uint totalSupply = totalSupply();
    for (uint i = 0; i < totalSupply; i++) {
      uint tokenId = tokenByIndex(i);
      // multi normalized by the multi sum
      uint relativeMulti = multis.multiProducts[i]*10000 / multis.multiProductsSum;
      // relative dyad delta for each nft
      uint relativeDyadDelta = PoolLibrary.percentageOf(dyadDelta, relativeMulti);

      Nft memory nft = idToNft[tokenId];

      // xp accrual happens only when there is a burn.
      uint xpAccrual;
      // there can only be xp accrual if deposit is not 0 
      if (mode == Mode.BURNING && nft.deposit > 0) {
        // normal accrual
        xpAccrual = relativeDyadDelta*100 / (multis.xpMultis[i]);
        // boost for the address calling this function
        if (!isBoosted && msg.sender == ownerOf(tokenId)) {
          isBoosted = true;
          xpAccrual *= 2;
        }
      }

      // update memory nft data
      if (mode == Mode.BURNING) {
        nft.deposit -= int(relativeDyadDelta);
        nft.xp      += xpAccrual/(10**18); // normalize by the dyad decimals
      } else {
        // NOTE: there is no xp accrual in Mode.MINTING
        nft.deposit += int(relativeDyadDelta);
      }

      nft.deposit < 0 ? nft.isLiquidatable = true 
                      : nft.isLiquidatable = false;

      idToNft[tokenId] = nft;

      // check if this is a new xp minimum/maximum for this sync
      if (nft.xp < minXp) { minXp = nft.xp; }
      if (nft.xp > maxXp) { maxXp = nft.xp; }
    }

    // save new min/max xp in storage
    MIN_XP = minXp;
    MAX_XP = maxXp;

    return dyadDelta;
  }

  // NOTE: calculation of the multis is determined by the `mode`
  function calcMultis(Mode mode) private view returns (Multis memory) {
    uint nftTotalSupply = totalSupply();
    uint multiProductsSum;
    uint[] memory multiProducts = new uint[](nftTotalSupply);
    uint[] memory xpMultis      = new uint[](nftTotalSupply);

    for (uint i = 0; i < nftTotalSupply; i++) {
      // get nft by token id
      Nft memory nft = idToNft[tokenByIndex(i)];

      uint multiProduct; // 0 by default
      uint xpMulti;      // 0 by default

      if (nft.deposit > 0) {
        // NOTE: From here on, uint(nft.deposit) is fine because it is not negative
        uint xpDelta =  MAX_XP - MIN_XP;
        if (xpDelta == 0) { xpDelta = 1; } // avoid division by 0
        uint xpScaled = ((nft.xp-MIN_XP)*10000) / xpDelta;
        uint mintAvgMinted = ((nft.withdrawn+uint(nft.deposit))*10000) / (dyad.totalSupply()/(nftTotalSupply+1));
        if (mode == Mode.BURNING && mintAvgMinted > 20000) { mintAvgMinted = 20000; } // limit to 200%
        xpMulti = PoolLibrary.getXpMulti(xpScaled/100);
        if (mode == Mode.BURNING) { xpMulti = 300-xpMulti; } // should be 292: 242+50
        uint depositMulti = (uint(nft.deposit)*10000) / (uint(nft.deposit)+(nft.withdrawn+1));
        multiProduct = xpMulti * (mode == Mode.BURNING ? mintAvgMinted : depositMulti) / 100;
      } 

      multiProducts[i]  = multiProduct;
      multiProductsSum  += multiProduct;
      xpMultis[i]       = xpMulti;
    }

    // so we avoid dividing by 0 in `sync`
    if (multiProductsSum == 0) { multiProductsSum = 1; }

    return Multis(multiProducts, multiProductsSum, xpMultis);
  }
}
