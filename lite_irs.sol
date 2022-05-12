// SPDX-License-Identifier: Apache-2.0

pragma solidity = 0.8.9;

import "./voltz-core/contracts/interfaces/IERC20Minimal.sol";
import "./voltz-core/contracts/rate_oracles/AaveRateOracle.sol";
import "./voltz-core/contracts/interfaces/aave/IAaveV2LendingPool.sol";
import "./voltz-core/contracts/utils/WadRayMath.sol";

contract LiteIRS {

    // Constants
    uint constant FIXED_RATE_WAD = 3 * 10**16;
    uint constant LIQUIDATOR_FEE = 5 * 10**15;

    // Trader struct layout
    struct Trader {
        address payable addr;
        uint256 margin;
    }

    // State variable definitions
    Trader private fixed_taker;
    Trader private variable_taker;
    uint256 private notional;
    uint256 private maturity; // uint representing timestamp
    uint256 private creation_date; // uint representing timestamp
    uint256 private margin_requirement;

    IERC20Minimal private underlying;
    AaveRateOracle private rate_oracle;
    IAaveV2LendingPool private lending_pool;
    

    modifier isParty() {
        // Check of sender is one of the parties involved in the contract
        require(msg.sender == fixed_taker.addr || msg.sender == variable_taker.addr, "Caller is not party");
        _;
    }

    /*@param underlying_ address of the ERC20 token representing the underlying (USDC)
     * @param rate_oracle_ oracle from which we will get the variable rates
     * @param lending_pool_ aave lending pool
     * @dev init contract params
     */
    constructor (
        IERC20Minimal underlying_,
        IAaveV2LendingPool lending_pool_
        ) {
        // Check token address exists
        require(address(underlying_) != address(0), "underlying must exist");
        // Check token address exists
        require(address(lending_pool_) != address(0), "underlying must exist");
        // init token
        underlying = underlying_;
        // init oracle with empty observations and times. 
        uint32[] memory times;
        uint256[] memory obs;
        rate_oracle = new AaveRateOracle(lending_pool_, underlying_, times, obs);
        // init lending pool 
        lending_pool = lending_pool_;
    }

    /**@param fixed_taker_addr_ address of fixed taker
     * @param variable_taker_addr_ address of variable taker
     * @param notional_ of the IRS 
     * @param maturity_ of the contract
     * @dev Contract initialization
     */
    function init_contract (
        address payable fixed_taker_addr_, 
        address payable variable_taker_addr_,       
        uint256 notional_, 
        uint256 maturity_) public isParty{
        
        // Initialize parties involved in the trade
        fixed_taker = Trader(fixed_taker_addr_, WadRayMath.wadDiv(notional_ * WadRayMath.WAD, 10 * WadRayMath.WAD));
        variable_taker = Trader(variable_taker_addr_, WadRayMath.wadDiv(notional_ * WadRayMath.WAD, 10 * WadRayMath.WAD)); 

        // Contract terms
        notional = notional_ * WadRayMath.WAD;
        maturity = maturity_;
        creation_date = block.timestamp;
        margin_requirement = WadRayMath.wadDiv(7 * notional * WadRayMath.WAD, 100 * WadRayMath.WAD);

        // Init margin requirement
        init_margin();
    }

    function init_margin() private {
        // Set margin requirements
        uint256 _total_margin = fixed_taker.margin + variable_taker.margin;
        bool _success = underlying.approve(address(this), _total_margin); // Parties involved in the contract have to approve previously contract
        if (_success){
            // Let the contract transfer the total margin to its address
            underlying.transfer(address(this), _total_margin);
        } else {
            revert("Contract is not approved.");
        }
    }

    /**
     * @dev overloads settle function 
     */
    function settle_at_maturity() public isParty {
        settle(maturity);
    }

    /**
     * @dev overloads settle function 
     */
    function settle(uint to) private {
        uint256 _variable = rate_oracle.getRateFromTo(creation_date, to);
        // settle position
        // Apparently uint does not support negative numbers. Thus, I need to mark to market in every case
        if(FIXED_RATE_WAD < _variable) {
            uint256 mark_to_market = (_variable - FIXED_RATE_WAD) * notional * WadRayMath.WAD;
            require(fixed_taker.margin >= mark_to_market, "Margin is not sufficient to settle the contract.");
            underlying.transfer(variable_taker.addr, mark_to_market);
            fixed_taker.margin =  fixed_taker.margin - mark_to_market;
        } else if (FIXED_RATE_WAD > _variable){
            uint256 mark_to_market = (FIXED_RATE_WAD - _variable) * notional * WadRayMath.WAD;
            require(variable_taker.margin >= mark_to_market, "Margin is not sufficient to settle the contract.");
            underlying.transfer(fixed_taker.addr, mark_to_market);
            variable_taker.margin =  variable_taker.margin - mark_to_market;
        }
        // If there is more margin available, divide it and transfer it to the parties involved in trade.
        uint256 margin_left = underlying.balanceOf(address(this));
        // If margin left greater than 2 transfer i
        if (margin_left > 0){
            underlying.transfer(fixed_taker.addr, fixed_taker.margin);
            underlying.transfer(fixed_taker.addr, variable_taker.margin);
        }
    }

    /**
     * @dev Liquidate position
     */
    function liquidate() public {
        // Check for margin requirement
        if (check_margin_requirement(margin_requirement)){
            uint _liquidation_fee = LIQUIDATOR_FEE * notional;
            underlying.transfer(msg.sender, _liquidation_fee);
            update_margins(margin_requirement, _liquidation_fee);
            settle(block.timestamp);
        }
    }

    /**
     * @dev Check if position is under margin requirement
     */
    function check_margin_requirement(uint256 threshold) private view returns(bool) {
        // We need to express the 7% of the notional in Wads
        if(fixed_taker.margin < threshold || variable_taker.margin < threshold) return true;
        return false;
    }

    /**
    * @dev Update margin in case of liquidation
    */
    function update_margins(uint256 threshold, uint256 deductable_amount) private {
        if(fixed_taker.margin < threshold) fixed_taker.margin = fixed_taker.margin - deductable_amount;
        if (variable_taker.margin < threshold) variable_taker.margin = variable_taker.margin - deductable_amount;
    }
}