pragma solidity 0.4.21;
pragma experimental "v0.5.0";

import "./math/SafeMath.sol";
import "./tokens/BountieToken.sol";


contract BountieTokenSale is Owners(false) {

    using SafeMath for uint256;

    struct Period {
        uint startTime;
        uint endTime;
    }

    uint public totalFund;
    uint public saleStart;
    uint public saleEnd;
    uint public tiers;
    uint public tokensPerETH = 4000;
    uint parties = 0;
    uint team = 1;

    mapping (address => bool) public whitelist;
    mapping (address => uint) public contributions;
    mapping (uint => Period) public tierPeriod;
    mapping (uint => bool) public allocCollected;
    mapping (uint => uint) public allocAmount;
    mapping (uint => uint) public tierTokensOffered;
    mapping (uint => uint) public tierTokensAvailable;
    mapping (uint => uint) public tierMultiplier;
    mapping (uint => bool) public tierActivated;

    address public multisig;
    address public whitelister;
    address public timeLockedWallet;

    BountieToken bountieToken;

    event Contribute(uint blkTs, address indexed contributor, uint amount);
    event Whitelisted(uint blkTs, address indexed contributor);

  // public - START ------------------------------------------------------------
    function BountieTokenSale(
        address _bountieToken,
        address _multisig,
        address _whitelister,
        address _timeLockedWallet,
        uint _saleStart,
        uint[] _tierTokensOffered,
        uint[] _tierDurationDays,
        uint[] _tierMultiplier
        ) public {
        require(_bountieToken != address(0x0));
        require(_multisig != address(0x0));
        require(_whitelister != address(0x0));
        require(_timeLockedWallet != address(0x0));
        assert(_tierTokensOffered.length == _tierDurationDays.length);
        assert(_tierTokensOffered.length == _tierMultiplier.length);
        tiers = _tierTokensOffered.length;

        bountieToken = BountieToken(_bountieToken);
        multisig = _multisig;
        whitelister = _whitelister;
        timeLockedWallet = _timeLockedWallet;

        setSaleInformation(_saleStart, _tierTokensOffered, _tierDurationDays, _tierMultiplier);

        allocAmount[parties] = 120000000 * (10**bountieToken.decimals());
        allocAmount[team] = 20000000 * (10**bountieToken.decimals());
    }

    function setSaleInformation(
        uint _saleStart,
        uint[] _amount,
        uint[] _days,
        uint[] _multiplier
    )
        internal
    {
        saleStart = _saleStart;
        for (uint i=0; i < _amount.length; i++) {
            tierTokensOffered[i] = _amount[i].mul(10**bountieToken.decimals());
            tierTokensAvailable[i] = tierTokensOffered[i];
            if (i == 0) {
                tierPeriod[i] = Period({startTime: saleStart, endTime: saleStart + (_days[i] * 1 days)});
            } else {
                tierPeriod[i] = Period({
                    startTime: tierPeriod[i-1].endTime,
                    endTime: tierPeriod[i-1].endTime + (_days[i] * 1 days)
                });
            }
            tierMultiplier[i] = _multiplier[i];
        }
        saleEnd = tierPeriod[tiers-1].endTime;
    }

    /**
     * @dev accepts ether, records contributions, and splits payment if referral code exists.
     *   contributor must be whitelisted, and sends the min ETH required.
     */
    function () external payable {
        require(isWhitelisted(msg.sender));
        require(msg.value > 0);
        require(now >= saleStart && now <= saleEnd);

        uint currentTier = getCurrentTier();
        if (currentTier != 0 && tierActivated[currentTier] == false) {
            if (tierTokensAvailable[currentTier-1] > 0) {
                tierTokensAvailable[currentTier] = tierTokensAvailable[currentTier]
                    .add(tierTokensAvailable[currentTier-1]);
            }
            tierActivated[currentTier] = true;
        }
        uint availableTokens = tierTokensAvailable[currentTier];
        require(availableTokens > 0);
        uint tokenRate = tokensPerETH.mul(tierMultiplier[currentTier]).div(100);

        uint contribution = msg.value;

        uint intendedTokens = tokenRate.mul(
            10**bountieToken.decimals()
        ).mul(contribution).div(1 ether);

        if (intendedTokens <= availableTokens) {
            // intended number of tokens available
            tierTokensAvailable[currentTier] = tierTokensAvailable[currentTier].sub(intendedTokens);
        } else {
            // intended number of tokens not as per availability
            intendedTokens = availableTokens;
            contribution = availableTokens.mul(1 ether).div(tokenRate.mul(10**bountieToken.decimals()));
            msg.sender.transfer(msg.value.sub(contribution));
            tierTokensAvailable[currentTier] = 0;
        }
        emit Contribute(now, msg.sender, contribution);
        contributions[msg.sender] = contributions[msg.sender].add(contribution);

        multisig.transfer(contribution);
        bountieToken.mint(msg.sender, intendedTokens);
        totalFund = totalFund.add(contribution);
    }

    function getCurrentTier() public view returns (uint) {
        for (uint i = 0; i < tiers; i++) {
            if (now >= tierPeriod[i].startTime && now < tierPeriod[i].endTime) {
                return i;
            }
        }
    }

    /**
     * @dev Checks if `_contributor` is in the whitelist.
     * @param _contributor address The address of contributor.
     */
    function isWhitelisted(address _contributor) public constant returns (bool) {
        return (whitelist[_contributor] == true);
    }
    // public - END --------------------------------------------------------------


    // ownerOnly - START ---------------------------------------------------------
    /**
     * @dev Allows owners to update `_whitelister` as new whitelister.
     * @param _whitelister address The address of new whitelister.
     */
    function updateWhitelister(address _whitelister) public ownerOnly {
        whitelister = _whitelister;
    }

    function assignToMultisig() public ownerOnly {
        assignToken(parties, multisig);
    }

    function assignToTeam() public ownerOnly {
        assignToken(team, timeLockedWallet);
    }

    function assignToken(uint _index, address _destination) private {
        require(allocCollected[_index] == false);
        bountieToken.mint(_destination, allocAmount[_index]);
        allocCollected[_index] = true;
    }
  // ownerOnly - END -----------------------------------------------------------


    // opsAdmin - START ----------------------------------------------------------
    /**
     * @dev Allows opsAdmin to add `_contributor` to the whitelist.
     * @param _contributor address The address of contributor.
     */
    function whitelist(address _contributor) public whitelisterOnly {
        whitelist[_contributor] = true;
        emit Whitelisted(now, _contributor);
    }
    // opsAdmin - END ------------------------------------------------------------

    // modifier - START ----------------------------------------------------------
    /**
     * @dev throws if sender is not whitelister.
     */
    modifier whitelisterOnly {
        require(msg.sender == whitelister);
        _;
    }
    // modifier - END ------------------------------------------------------------
}
