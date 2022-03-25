// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.10;

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockRewards} from "flywheel/test/mocks/MockRewards.sol";

import "flywheel/FlywheelCore.sol";

import "../xTRIBE.sol";

contract FlywheelTest is DSTestPlus {
    FlywheelCore flywheel;
    MockRewards rewards;

    MockERC20 strategy;
    MockERC20 rewardToken;

    xTRIBE xTribe;

    function setUp() public {
        rewardToken = new MockERC20("test token", "TKN", 18);

        strategy = new MockERC20("test strategy", "TKN", 18);

        flywheel = new FlywheelCore(
            rewardToken,
            MockRewards(address(0)),
            IFlywheelBooster(address(0)),
            address(this),
            Authority(address(0))
        );

        rewards = new MockRewards(flywheel);

        flywheel.setFlywheelRewards(rewards);

        xTribe = new xTRIBE(
            rewardToken,
            address(this),
            Authority(address(0)),
            1000, // cycle of 1000
            100 // freeze window of 100
        );
    }

    function testXTribeDelegations(
        address user,
        address delegate,
        uint128 mintAmount,
        uint128 delegationAmount,
        uint128 transferAmount
    ) public {
        hevm.assume(mintAmount != 0 && transferAmount <= mintAmount);

        rewardToken.mint(user, mintAmount);
        xTribe.setMaxDelegates(1);

        hevm.startPrank(user);
        rewardToken.approve(address(xTribe), mintAmount);
        xTribe.deposit(mintAmount, user);

        require(xTribe.balanceOf(user) == mintAmount);

        if (delegationAmount > mintAmount) {
            hevm.expectRevert(abi.encodeWithSignature("DelegationError()"));
            xTribe.delegate(delegate, delegationAmount);
            return;
        }
        xTribe.delegate(delegate, delegationAmount);
        require(xTribe.userDelegatedVotes(user) == delegationAmount);
        require(xTribe.numCheckpoints(delegate) == 1);
        require(xTribe.checkpoints(delegate, 0).votes == delegationAmount);

        hevm.roll(block.number + 10);
        xTribe.transfer(delegate, transferAmount);
        if (mintAmount - transferAmount < delegationAmount) {
            require(xTribe.userDelegatedVotes(user) == 0);
            require(xTribe.numCheckpoints(delegate) == 2);
            require(xTribe.checkpoints(delegate, 0).votes == delegationAmount);
            require(xTribe.checkpoints(delegate, 1).votes == 0);
        } else {
            require(xTribe.userDelegatedVotes(user) == delegationAmount);
            require(xTribe.numCheckpoints(delegate) == 1);
            require(xTribe.checkpoints(delegate, 0).votes == delegationAmount);
        }
    }

    function testXTribeGauges(
        address user,
        address delegate,
        uint128 mintAmount,
        uint128 delegationAmount,
        uint128 transferAmount,
        uint32 timestamp
    ) public {
        // TODO
    }

    function testXTribeRewards(
        address user1,
        address user2,
        uint128 user1Amount,
        uint128 user2Amount,
        uint128 rewardAmount,
        uint32 rewardTimestamp,
        uint32 user2DepositTimestamp
    ) public {
        rewardTimestamp = rewardTimestamp % xTribe.rewardsCycleLength();
        user2DepositTimestamp =
            user2DepositTimestamp %
            xTribe.rewardsCycleLength();
        hevm.assume(
            user1Amount != 0 &&
                user2Amount != 0 &&
                user2Amount != type(uint128).max &&
                rewardAmount != 0 &&
                rewardTimestamp <= user2DepositTimestamp &&
                user1Amount < type(uint128).max / user2Amount
        );

        rewardToken.mint(user1, user1Amount);
        rewardToken.mint(user2, user2Amount);

        hevm.startPrank(user1);
        rewardToken.approve(address(xTribe), user1Amount);
        xTribe.deposit(user1Amount, user1);
        hevm.stopPrank();

        require(xTribe.previewRedeem(user1Amount) == user1Amount);

        hevm.warp(rewardTimestamp);
        rewardToken.mint(address(xTribe), rewardAmount);
        xTribe.syncRewards();

        require(xTribe.previewRedeem(user1Amount) == user1Amount);

        hevm.warp(user2DepositTimestamp);

        hevm.startPrank(user2);
        rewardToken.approve(address(xTribe), user2Amount);
        if (xTribe.convertToShares(user2Amount) == 0) {
            hevm.expectRevert(bytes("ZERO_SHARES"));
            xTribe.deposit(user2Amount, user2);
            return;
        }
        uint256 shares2 = xTribe.deposit(user2Amount, user2);
        hevm.stopPrank();

        assertApproxEq(
            xTribe.previewRedeem(shares2),
            user2Amount,
            (xTribe.totalAssets() / xTribe.totalSupply()) + 1
        );

        uint256 effectiveCycleLength = xTribe.rewardsCycleLength() -
            rewardTimestamp;
        uint256 beforeUser2Time = user2DepositTimestamp - rewardTimestamp;
        uint256 beforeUser2Rewards = (rewardAmount * beforeUser2Time) /
            effectiveCycleLength;

        assertApproxEq(
            xTribe.previewRedeem(user1Amount),
            user1Amount + beforeUser2Rewards,
            (xTribe.totalAssets() / xTribe.totalSupply()) + 1
        );

        hevm.warp(xTribe.rewardsCycleEnd());

        uint256 remainingRewards = rewardAmount - beforeUser2Rewards;
        uint256 user1Rewards = (remainingRewards * user1Amount) /
            (user1Amount + shares2);
        uint256 user2Rewards = (remainingRewards * shares2) /
            (user1Amount + shares2);

        hevm.assume(shares2 < type(uint128).max / xTribe.totalAssets());
        assertApproxEq(
            xTribe.previewRedeem(shares2),
            user2Amount + user2Rewards,
            (xTribe.totalAssets() / xTribe.totalSupply()) + 1
        );

        hevm.assume(user1Amount < type(uint128).max / xTribe.totalAssets());
        assertApproxEq(
            xTribe.previewRedeem(user1Amount),
            user1Amount + beforeUser2Rewards + user1Rewards,
            (xTribe.totalAssets() / xTribe.totalSupply()) + 1
        );
    }
}
