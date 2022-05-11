pragma solidity >=0.7.0 <0.9.0;

import "./voltz-core/contracts/interfaces/IERC20Minimal.sol";
import "./voltz-core/contracts/rate_oracles/AaveRateOracle.sol";
import "./voltz-core/contracts/interfaces/aave/IAaveV2LendingPool.sol"
import "./voltz-core/contracts/utils/WadRayMath.sol"

contract LiteIRS {

    // Constants
    uint constant FIXED_RATE_WAD = 0.03 * WadRayMath.WAD;

    // Trader struct layout
    struct Trader {
        address payable addr;
        uint256 margin;
    }

    // State variable definitions
    Trader private fixed_taker;
    Trader private variable_taker;
    uint256 private notional;
    uint256 private maturity; // timestamp
    uint256 private creation_date;

    IERC20Minimal private underlying;
    AaveRateOracle private rate_oracle;
    IAaveV2LendingPool private lending_pool;
    

    modifier isParty() {
        // Check of sender is one of the parties involved in the contract
        require(msg.sender == fixed_taker.addr || msg.sender == variable_taker.addr, "Caller is not party");
        _;
    }

    
    /*@param underlying_ ERC20 token representing the underlying (USDC)
     * @param rate_oracle_ oracle from which we will get the variable rates
     * @param lending_pool_ aave lending pool
     * @dev init contract params
     */
    constructor(
        IERC20Minimal underlying_,
        AaveRateOracle rate_oracle_,
        IAaveV2LendingPool lending_pool_
        ) {
        
        // Check token address exists
        require(address(_underlying) != address(0), "underlying must exist");
        // init token
        underlying = underlying_;
        // init oracle with empty observations and times. 
        rate_oracle = new AaveRateOracle(lending_pool_, underlying_, [], []);
        // init lending pool 
        lending_pool = lending_pool_;
    }

    /**@param fixed_taker_address address of fixed taker
     * @param variable_taker_address address of variable taker
     * @param notional notional of the IRS 
     * @param maturity maturity of the contract
     * @dev Contract initialization
     */
    function init_contract public(  
        addres payable fixed_taker_addr_, 
        addres payable variable_taker_addr_,       
        uint256 notional_, 
        uint256 maturity_,
        uint256 frequency_) public {
        
        // Initialize parties involved in the trade
        fixed_taker = Trader(fixed_taker_addr_, notional_ * 0.1 * WadRayMath.WAD);
        variable_taker = Trader(variable_taker_addr_, notional_ * 0.1 * WadRayMath.WAD); // a variable rate provided by msg.sender is assumed

        // Contract terms
        notional = notional_ * WadRayMath.WAD;
        maturity = maturity_;
        creation_date = block.timestamp;

        // Init margin requirement
        init_margin();
    }

    function init_margin private () {
        // Set margin requirements
        uint256 _total_margin = fixed_taker.margin + variable_taker.margin;
        bool _success = underlying.approve(aaddress(this), _total_margin);
        if (_success){
            // Let the contract transfer the total margin to its address
            underlying.transfer(address(this), _total_margin);
        } else {
            revert("Contract is not approved.")
        }
    }

    /**
     * @dev overloads settle function 
     */
    function settle_at_maturity(uint to) public isParty {
        settle(maturity);
    }

    /**
     * @dev overloads settle function 
     */
    function settle(uint to) private {
        uint _variable = rate_oracle.getRateFromTo(creation_date, to);
        mark_to_market = (FIXED_RATE_WAD - _variable) * notional * WadRayMath.WAD;
        // settle position
        if(mark_to_market < 0) {
            require(fixed_taker.margin > mark_to_market), "Margin is not sufficient to settle the contract.");
            underlying.transfer(variable_taker.addr, -mark_to_market);
            fixed_taker.margin =  fixed_taker.margin - mark_to_market;
        } else if (mark_market_market > 0){
            require(variable_taker.margin > mark_to_market), "Margin is not sufficient to settle the contract.");
            underlying.transfer(fixed_taker.addr, mark_to_market);
            variable_taker.margin =  variable_taker.margin - mark_to_market;
        }
        // If there is more margin available, divide it and transfer it to the parties involved in trade.
        uint256 margin_left = underlying.balanceOf(address(this);
        if (margin_left > 0)){
            underlying.transfer(fixed_taker.addr, margin_left / 2);
            underlying.transfer(fixed_taker.addr, margin_left / 2);
        }
    }

    /**
     * @dev Liquidate position
     */
    function liquidate() public canLiquidate {
        check_margin_requirement();
        settle(block.timesamp);
    }

    /**
     * @dev Chack if position is under margin requirement
     */
    function check_margin_requirement() private {
        if(fixed_taker.margin < 0.07 * notional * WadRayMath.WAD)
        {
            return fixed_taker.addr;
        }
        if(variable_taker.margin < 0.07 * notional * WadRayMath.WAD){
            return variable_taker.addr;
        }
    }

}