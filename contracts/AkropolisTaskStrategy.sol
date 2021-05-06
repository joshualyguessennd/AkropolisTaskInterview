// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

interface YieldFarming {
    function stakeInPool(uint256 _pid, uint256 _amount) public;
    function withdrawFromPool(uint256 _pid, uint256 _amount) public;
    function poolInfo(uint256 _pid) external view returns (address, uint256, uint256, uint256);
    function stakerInfo(uint256 _pid, address _user) external view returns (uint256, uint256);
}

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";


contract AkropolisTaskStrategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public yieldfarming;
    address public reward;

    address private constant uniswapRouter = address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    address private constant weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    address public router;
    uint256 public pid;

    address[] public path;

    event Cloned(address indexed clone);

    constructor(
        address _vault,
        address _yieldfarming,
        address _reward,
        address _router,
        uint256 _pid
    ) public BaseStrategy(_vault) {
        _initializeStrat(_yieldfarming, _reward, _router, _pid);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _yiedfarming,
        address _reward,
        address _router,
        uint256 _pid
    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_yiedfarming, _reward, _router, _pid);
    }


    function _initializeStrat(
        address _yieldfarming,
        address _reward,
        address _router,
        uint256 _pid
    ) internal {
        require(router == address(0), "the yieldfarming has already been initialized");
        require(_router == uniswapRouter, "incorrect Router");

        maxReportDelay = 6300;
        profitFactor = 1500;
        debtThreshold = 1_000_000 * 1e18;
        yieldfarming = _yieldfarming;
        reward = _reward;
        router = _router;
        pid = _pid;
        

        (address poolToken, , ,) = YieldFarming(yieldfarming).poolInfo(pid);

        require(poolToken == address(want), "wrong pool id");

        want.safeApprove(_yiedfarming, uint256(-1));
        IERC20(reward).safeApprove(router, uint256(-1));
    }



    function cloneStrategy(
        address _vault,
        address _yieldfarming,
        address _reward,
        address _router,
        uint256 _pid
    ) external returns (address nStrategy) {
        nStrategy = this.cloneStrategy(_vault, msg.sender, msg.sender, msg.sender, _yieldfarming, _reward, _router, _pid);
    }


    function cloneStrategy(address _vault, address _strategist, address rewards, address _keeper, address _yieldfarming, address _reward, address _router,uint256  _pid) external returns (address nStrategy) {
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
        }

        AkropolisTaskStrategy(nStrategy).initialize(_vault, _strategist, _rewards, _keeper, _yiedfarming, _reward, _router, _pid);
        emit Cloned(newStrategy);
    }


    function setRouter(address _router) public onlyAuthorized {
        require(_router == uniswapRouter, "incorrect router address");
        router = _router;
        IERC20(reward).safeApprove(router, 0);
        IERC20(reward).safeApprove(router, uint256(-1));
    }

    function setPath(address[] calldata _path) public onlyGovernance {
        path = _path;
    }

    //Base contract methods 

    function name() external view override returns (string memory) {
        return "AkropolisTaskStrategy";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        (uint256 amount, ) =
            YieldFarming(yieldfarming).stakerInfo(pid, address(this));
        return want.balanceOf(address(this)).add(amount);
    }


    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        YieldFarming(yieldfarming).stakeInPool(pid, 0);

        _sell();

        uint256 assets = estimatedTotalAssets();
        uint256 wantBal = want.balanceOf(address(this));

        uint256 debt = vault.strategies(address(this)).totalDebt;

        if (assets > debt) {
            _debtPayment = _debtOutstanding;
            _profit = assets - debt;

            uint256 amountToFree = _profit.add(_debtPayment);

            if (amountToFree > 0 && wantBal < amountToFree) {
                liquidatePosition(amountToFree);

                uint256 newLoose = want.balanceOf(address(this));

                //if we dont have enough money adjust _debtOutstanding and only change profit if needed
                if (newLoose < amountToFree) {
                    if (_profit > newLoose) {
                        _profit = newLoose;
                        _debtPayment = 0;
                    } else {
                        _debtPayment = Math.min(
                            newLoose - _profit,
                            _debtPayment
                        );
                    }
                }
            }
        } else {
            //serious loss should never happen but if it does lets record it accurately
            _loss = debt - assets;
        }
    }


    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }

        uint256 wantBalance = want.balanceOf(address(this));
        YieldFarming(yieldfarming).stakeInPool(pid, wantBalance);
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 totalAssets = want.balanceOf(address(this));
        if (_amountNeeded > totalAssets) {
            uint256 amountToFree = _amountNeeded.sub(totalAssets);

            (uint256 amount, ) =
                YieldFarming(yieldfarming).stakerInfo(pid, address(this));
            if (amount < amountToFree) {
                amountToFree = amount;
            }
            if (amount > 0) {
                YieldFarming(yieldfarming).withdrawFromPool(pid, amountToFree);
            }

            _liquidatedAmount = want.balanceOf(address(this));
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }


    function prepareMigration(address _newStrategy) internal override {
        liquidatePosition(uint256(-1)); //withdraw all. does not matter if we ask for too much
        _sell();
    }

    function _sell() internal {

        uint256 rewardBal = IERC20(reward).balanceOf(address(this));
        if( rewardBal == 0){
            return;
        }


        if(path.length == 0){
            address[] memory tpath;
            if(address(want) != weth){
                tpath = new address[](3);
                tpath[2] = address(want);
            }else{
                tpath = new address[](2);
            }
            
            tpath[0] = address(reward);
            tpath[1] = weth;

            IUniswapV2Router02(router).swapExactTokensForTokens(rewardBal, uint256(0), tpath, address(this), now);
        }else{
            IUniswapV2Router02(router).swapExactTokensForTokens(rewardBal, uint256(0), path, address(this), now);
        }  

    }


    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}
}
