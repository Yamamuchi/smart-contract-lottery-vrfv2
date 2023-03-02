// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";

/// @title Smart contract lottery
/// @author Harvey C Yorke
/// @notice A lottery built on the Ethereum Blockchain. Players can enter the lottery by paying the require entry fee and once the max amount of players have entered a winner will be picked at random.
/// @dev Contract must be added as a VRF consumer before a winner can be picked.
contract Lottery is VRFConsumerBaseV2, Ownable {
    event RequestSent(uint256 requestId, uint32 numWords);
    event RequestFulfilled(uint256 requestId, uint256[] randomWords);

    struct RequestStatus {
        bool fulfilled; // whether the request has been successfully fulfilled
        bool exists; // whether a requestId exists
        uint256[] randomWords;
    }
    mapping(uint256 => RequestStatus) public s_requests; /* requestId --> requestStatus */

    AggregatorV3Interface internal ethUsdPriceFeed;
    VRFCoordinatorV2Interface COORDINATOR;
    uint64 s_subscriptionId;
    uint256[] public requestIds;
    uint256 public lastRequestId;
    bytes32 keyHash;
    uint32 callbackGasLimit = 2500000;
    uint16 requestConfirmations = 3;
    uint32 numWords = 1;

    // --------------------------------------------------------------------------------

    address payable[] public players;
    address payable public recentWinner;
    uint256 public currentPlayers;
    uint256 public maxPlayers;
    uint256 public usdEntryFee;

    // --------------------------------------------------------------------------------

    /// @dev Configure pricefeed and VRFv2, ensure subscription is funded with LINK.
    constructor(
        address _priceFeedAddress,
        address _vrfCoordinator,
        uint64 _subscriptionId,
        bytes32 _keyHash
    ) VRFConsumerBaseV2(_vrfCoordinator) {
        ethUsdPriceFeed = AggregatorV3Interface(_priceFeedAddress);
        COORDINATOR = VRFCoordinatorV2Interface(_vrfCoordinator);
        s_subscriptionId = _subscriptionId;
        keyHash = _keyHash;

        usdEntryFee = 50 * (10**18); // 18 decimal places
        maxPlayers = 2;
        currentPlayers = 0;
    }

    /// @notice Change the maximum amount of players required for the lottery to pick a winner and restart.
    /// @param _maxPlayers New max amount of players.
    function changeMaxPlayers(uint256 _maxPlayers) public onlyOwner {
        require(
            currentPlayers == 0,
            "Can't update max players until new lottery has started!"
        );
        maxPlayers = _maxPlayers;
    }

    /// @notice Change the entry fee for the lottery.
    /// @param _usdEntryFee New entry fee in USD.
    function changeUsdEntryFee(uint256 _usdEntryFee) public onlyOwner {
        require(
            currentPlayers == 0,
            "Can't update entry fee until new lottery has started!"
        );
        usdEntryFee = _usdEntryFee * (10**18);
    }

    /// @notice Enter the lottery, paying the required entry fee. If the max amount of players has been reached a winner will be picked.
    /// @dev Contract must be added as a VRF consumer for function to run if maxPlayers == currentPlayers.
    function enter() public payable {
        require(msg.value >= getEntranceFee(), "Not enough ETH!");
        require(maxPlayers > players.length, "Player limit already reached");

        players.push(payable(msg.sender));
        currentPlayers += 1;

        if (maxPlayers == currentPlayers) {
            pickWinner();
        }
    }

    /// @notice Winner of the lottery is picked.
    /// @dev Request for 1 random word is made, callbackGasLimit is set to max so request will not be reverted.
    function pickWinner() private {
        uint256 requestId = COORDINATOR.requestRandomWords(
            keyHash,
            s_subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            numWords
        );
        s_requests[requestId] = RequestStatus({
            randomWords: new uint256[](0),
            exists: true,
            fulfilled: false
        });
        requestIds.push(requestId);
        lastRequestId = requestId;
        emit RequestSent(requestId, numWords);
    }

    /// @notice Winnings are transferred to the winning player and the lottery is reset.
    /// @dev Random number is sent to this function from VRF.
    /// @param _randomWords The random number requested.
    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] memory _randomWords
    ) internal override {
        require(s_requests[_requestId].exists, "request not found");
        s_requests[_requestId].fulfilled = true;
        s_requests[_requestId].randomWords = _randomWords;
        emit RequestFulfilled(_requestId, _randomWords);

        uint256 randomNumber = s_requests[_requestId].randomWords[0];

        require(randomNumber > 0, "Random not found!");
        uint256 indexOfWinner = randomNumber % players.length;
        recentWinner = players[indexOfWinner];
        recentWinner.transfer(address(this).balance);
        players = new address payable[](0);
        currentPlayers = 0;
    }

    /// @notice Converts entry fee in USD to Wei.
    /// @dev usdEntryFee is * by 10**18 to avoid floats and to get the value in Wei not Eth.
    /// @return costToEnter The cost of entering the lottery in Wei.
    function getEntranceFee() public view returns (uint256) {
        (, int256 price, , , ) = ethUsdPriceFeed.latestRoundData();
        uint256 adjustedPrice = uint256(price) * 10**10; // 18 decimal places, e.g. 1563000000000000000000

        uint256 costToEnter = (usdEntryFee * 10**18) / adjustedPrice; // * 10**18 to convert to wei, preventing float.
        return costToEnter;
    }

    /// @dev Check the status of VRF random request.
    function getRequestStatus(uint256 _requestId)
        external
        view
        returns (bool fulfilled, uint256[] memory randomWords)
    {
        require(s_requests[_requestId].exists, "request not found");
        RequestStatus memory request = s_requests[_requestId];
        return (request.fulfilled, request.randomWords);
    }

    /// @dev Contract added as consumer.
    function addConsumer() public onlyOwner {
        // Add a consumer contract to the subscription.
        COORDINATOR.addConsumer(s_subscriptionId, address(this));
    }
}
