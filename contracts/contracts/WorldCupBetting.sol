// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IReputationSystem {
    function updateReputation(address user, bool correct) external;
}

contract WorldCupBetting is ReentrancyGuard, Ownable {
    enum MarketStatus { Open, Closed, Resolved, Cancelled }

    struct Market {
        uint256 id;
        string question;
        string description;
        string[] outcomes;
        uint256 resolutionTime;
        address arbitrator;
        address creator;
        MarketStatus status;
        uint256 winningOutcome;
        address tokenAddress;
        uint256 totalVolume;
    }

    struct Bet {
        uint256 id;
        address bettor;
        uint256 marketId;
        uint256 outcomeIndex;
        uint256 amount;
        uint256 shares;
        bool claimed;
    }

    IReputationSystem public reputationSystem;
    uint256 public marketCount;
    uint256 public betCount;

    // 2% platform fee on winning payouts
    uint256 public constant FEE_PCT = 2;
    uint256 public constant FEE_BASE = 100;

    mapping(uint256 => Market) public markets;
    mapping(uint256 => mapping(uint256 => uint256)) public outcomePools;
    mapping(uint256 => mapping(uint256 => uint256)) public outcomeShares;
    mapping(uint256 => Bet) public bets;
    mapping(address => uint256[]) public userBets;
    mapping(uint256 => uint256[]) public marketBets;
    mapping(uint256 => bool) public isListed;
    mapping(uint256 => uint256) public listPrice;
    mapping(address => uint256) public fees;

    event MarketCreated(uint256 indexed marketId, address indexed creator, string question);
    event BetPlaced(uint256 indexed betId, uint256 indexed marketId, address indexed bettor, uint256 amount);
    event MarketResolved(uint256 indexed marketId, uint256 outcome);
    event Claimed(uint256 indexed betId, address indexed claimer, uint256 amount);
    event PositionSold(uint256 indexed betId, address seller, address buyer, uint256 amount);
    event FeesWithdrawn(address indexed token, uint256 amount);

    constructor(address reputationSystem_) Ownable(msg.sender) {
        reputationSystem = IReputationSystem(reputationSystem_);
    }

    function createMarket(
        string memory question,
        string memory description,
        string[] memory outcomes,
        uint256 resolutionTime,
        address arbitrator,
        address tokenAddress
    ) external returns (uint256) {
        require(outcomes.length >= 2, "need at least 2 outcomes");
        require(resolutionTime > block.timestamp, "resolution must be in future");
        require(arbitrator != address(0), "invalid arbitrator");

        marketCount++;
        Market storage m = markets[marketCount];
        m.id = marketCount;
        m.question = question;
        m.description = description;
        m.outcomes = outcomes;
        m.resolutionTime = resolutionTime;
        m.arbitrator = arbitrator;
        m.creator = msg.sender;
        m.status = MarketStatus.Open;
        m.tokenAddress = tokenAddress;

        emit MarketCreated(marketCount, msg.sender, question);
        return marketCount;
    }

    function placeBet(
        uint256 marketId,
        uint256 outcomeIndex,
        uint256 amount,
        uint256 minShares
    ) external payable returns (uint256) {
        require(marketId > 0 && marketId <= marketCount, "invalid market");

        Market storage m = markets[marketId];
        require(m.status == MarketStatus.Open, "market not open");
        require(block.timestamp < m.resolutionTime, "Market closed");
        require(outcomeIndex < m.outcomes.length, "invalid outcome");
        require(amount > 0, "amount must be > 0");

        if (m.tokenAddress == address(0)) {
            require(msg.value == amount, "wrong eth amount");
        } else {
            require(IERC20(m.tokenAddress).transferFrom(msg.sender, address(this), amount), "erc20 transfer failed");
        }

        uint256 shares = amount * 100;
        require(shares >= minShares, "Slippage exceeded");

        betCount++;
        bets[betCount] = Bet(betCount, msg.sender, marketId, outcomeIndex, amount, shares, false);

        outcomePools[marketId][outcomeIndex] += amount;
        outcomeShares[marketId][outcomeIndex] += shares;
        m.totalVolume += amount;

        userBets[msg.sender].push(betCount);
        marketBets[marketId].push(betCount);

        emit BetPlaced(betCount, marketId, msg.sender, amount);
        return betCount;
    }

    function resolveMarket(uint256 marketId, uint256 winningOutcome) external {
        require(marketId > 0 && marketId <= marketCount, "invalid market");

        Market storage m = markets[marketId];
        require(msg.sender == m.arbitrator, "Only arbitrator");
        require(m.status == MarketStatus.Open, "market not open");
        require(block.timestamp >= m.resolutionTime, "Too early");
        require(winningOutcome < m.outcomes.length, "invalid outcome");

        m.status = MarketStatus.Resolved;
        m.winningOutcome = winningOutcome;

        emit MarketResolved(marketId, winningOutcome);
    }

    // winner gets proportional pool minus 2% fee; loser records reputation only
    function claimWinnings(uint256 betId) external nonReentrant {
        require(betId > 0 && betId <= betCount, "invalid bet");

        Bet storage b = bets[betId];
        Market storage m = markets[b.marketId];
        require(msg.sender == b.bettor, "not your bet");
        require(!b.claimed, "Already claimed");
        require(m.status == MarketStatus.Resolved, "market not resolved");

        if (b.outcomeIndex == m.winningOutcome) {
            b.claimed = true;

            uint256 winnerShares = outcomeShares[b.marketId][m.winningOutcome];
            uint256 totalPool = getTotalPool(b.marketId);
            uint256 payout = b.shares * totalPool / winnerShares;
            uint256 fee = payout * FEE_PCT / FEE_BASE;
            uint256 net = payout - fee;

            fees[m.tokenAddress] += fee;

            reputationSystem.updateReputation(msg.sender, true);

            if (m.tokenAddress == address(0)) {
                (bool ok, ) = payable(msg.sender).call{value: net}("");
                require(ok, "eth transfer failed");
            } else {
                require(IERC20(m.tokenAddress).transfer(msg.sender, net), "erc20 transfer failed");
            }

            emit Claimed(betId, msg.sender, net);
        } else {
            b.claimed = true;
            reputationSystem.updateReputation(msg.sender, false);
        }
    }

    function listPosition(uint256 betId, uint256 price) external {
        require(price > 0, "price must be > 0");

        Bet storage b = bets[betId];
        require(msg.sender == b.bettor, "not your bet");
        require(!b.claimed, "already claimed");
        require(markets[b.marketId].status == MarketStatus.Open, "market not open");

        isListed[betId] = true;
        listPrice[betId] = price;
    }

    function cancelListing(uint256 betId) external {
        Bet storage b = bets[betId];
        require(msg.sender == b.bettor, "not your bet");
        require(isListed[betId], "not listed");

        isListed[betId] = false;
        listPrice[betId] = 0;
    }

    function buyPosition(uint256 betId) external payable nonReentrant {
        require(isListed[betId], "position not for sale");

        Bet storage b = bets[betId];
        Market storage m = markets[b.marketId];
        address seller = b.bettor;
        uint256 price = listPrice[betId];

        b.bettor = msg.sender;
        isListed[betId] = false;
        userBets[msg.sender].push(betId);

        if (m.tokenAddress == address(0)) {
            require(msg.value >= price, "insufficient eth");
            (bool ok, ) = payable(seller).call{value: price}("");
            require(ok, "eth transfer failed");
            if (msg.value > price) {
                (bool refundOk, ) = payable(msg.sender).call{value: msg.value - price}("");
                require(refundOk, "refund failed");
            }
        } else {
            require(msg.value == 0, "use erc20 not eth");
            require(IERC20(m.tokenAddress).transferFrom(msg.sender, seller, price), "erc20 transfer failed");
        }

        emit PositionSold(betId, seller, msg.sender, price);
    }

    function withdrawFees(address tokenAddress) external onlyOwner nonReentrant {
        uint256 available = fees[tokenAddress];
        require(available > 0, "no fees to withdraw");

        fees[tokenAddress] = 0;

        if (tokenAddress == address(0)) {
            (bool ok, ) = payable(owner()).call{value: available}("");
            require(ok, "eth transfer failed");
        } else {
            require(IERC20(tokenAddress).transfer(owner(), available), "erc20 transfer failed");
        }

        emit FeesWithdrawn(tokenAddress, available);
    }

    function getAvailableFees(address tokenAddress) external view returns (uint256) {
        return fees[tokenAddress];
    }

    function getTotalPool(uint256 marketId) public view returns (uint256) {
        Market storage m = markets[marketId];
        uint256 total;
        for (uint256 i = 0; i < m.outcomes.length; i++) {
            total += outcomePools[marketId][i];
        }
        return total;
    }

    // amount * 100 — no fractions, keeps shares whole
    function calculateShares(uint256, uint256, uint256 amount) public pure returns (uint256) {
        return amount * 100;
    }

    function getPrice(uint256 marketId, uint256 outcomeIndex) public view returns (uint256) {
        uint256 pool = outcomePools[marketId][outcomeIndex];
        uint256 total = getTotalPool(marketId);
        if (total == 0) return 50;
        return pool * 100 / total;
    }

    function getUserBets(address user) external view returns (uint256[] memory) {
        return userBets[user];
    }

    function getMarketBets(uint256 marketId) external view returns (uint256[] memory) {
        return marketBets[marketId];
    }

    function getMarket(uint256 marketId)
        external
        view
        returns (
            uint256 id,
            string memory question,
            string memory description,
            string[] memory outcomes,
            uint256 resolutionTime,
            address arbitrator,
            address creator,
            MarketStatus status,
            uint256 totalVolume,
            address tokenAddress
        )
    {
        Market storage m = markets[marketId];
        return (m.id, m.question, m.description, m.outcomes, m.resolutionTime, m.arbitrator, m.creator, m.status, m.totalVolume, m.tokenAddress);
    }
}
