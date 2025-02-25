// SPDX-License-Identifier: MIT

/*
V1 Change: Removed unused functions.
V2 Change: Changed isLP function using staticcall.
V3 Change: For compoundrewards function, a boolean (compoundLP) is used instead of isLP(). Renamed some functions.
V4 Change: Added setMC function and clearPools functions so that the same contract can be recycled for multiple MCs.
V4.1 Changes:
- Fixed an error with _dumpLP
- Change the format of poolInfo so that it only reads the first element which should be (address _lptoken).
V4.3 Changes:
- Updated to work with modified AMM router with different swap function signatures
*/

pragma solidity ^0.8.1;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function name() external view returns (string memory);
}

interface Pair is IERC20 {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

// Updated router interface to match the new router's specification
interface IModifiedRouter {
    struct Route {
        address from;
        address to;
        bool stable;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
    );

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        Route[] calldata routes,
        address to
    ) external payable returns (uint256 amountOut);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
}

interface Masterchef {
    function deposit(uint256 _pid, uint256 _amount) external;
    function withdraw(uint256 _pid, uint256 _wantAmt) external;
    function poolInfo(uint256 pid) external view returns (address lpToken);
    function emergencyWithdraw(uint256 _pid) external;
    function userInfo(uint256 _pid, address _user) external view returns (uint256 amount, uint256 rewardDebt);
}

contract Vault {

    // INITIAL PARAMETERS:
    Masterchef public masterchef = Masterchef(0x2E585B96A2Ef1661508110E41c005bE86b63fc34);

    IModifiedRouter public router = IModifiedRouter(0xA047e2AbF8263FcA7c368F43e2f960A06FD9949f); // SWAPX

    IERC20 public osonic = IERC20(0xb1e25689D55734FD3ffFc939c4C3Eb52DFf8A794);
    IERC20 public token = IERC20(0xB3804bF38bD170ef65b4De8536d19a8e3600C0A9); // Reward token.
    IERC20 public convertToken = IERC20(0xb1e25689D55734FD3ffFc939c4C3Eb52DFf8A794); // Sell reward token to this token with harvest() function.

    // If the compounding pool uses LP, define both pooltoken0 and pooltoken1 are used.
    // If single stake, only pooltoken0 is used. No need to define pooltoken1 (still need to declare).
    IERC20 public pooltoken0 = osonic;
    IERC20 public pooltoken1;

    // These routes need to be defined to ensure tokens are sold using the most liquid route.
    // Modified to use the new Route struct format
    IModifiedRouter.Route[] public tokenToconvertToken;
    IModifiedRouter.Route[] public tokenTopooltoken0;

    uint256 public depositPID = 0;
    bool public compoundLP = false;

    IModifiedRouter.Route[] public pooltoken0Topooltoken1;
    IModifiedRouter.Route[] public pooltoken1Topooltoken0;
    IModifiedRouter.Route[] public token1Totoken0;

    address public owner;
    address public harvester;

    address proposedOwner = address(0);
    uint256[] public pools;

    mapping(uint256 => IModifiedRouter.Route[]) public dumpPath;
    mapping(uint256 => bool) public dumpPathExistence;

    constructor() {
        // Initialize routes with appropriate values
        _initializeRoutes();

        owner = msg.sender;
        harvester = 0x46F0469a56BEa9487851fA0bd5228EE793Ceaebb;

        token.approve(address(router), type(uint256).max);
        pooltoken0.approve(address(router), type(uint256).max);
        if (address(pooltoken1) != address(0)) pooltoken1.approve(address(router), type(uint256).max);

        if (compoundLP) {
            _updatePoolTokenRoutes();
        }

        // Initialize dump path for the deposit PID
        IModifiedRouter.Route memory defaultDumpRoute = IModifiedRouter.Route({
            from: address(pooltoken0),
            to: address(convertToken),
            stable: true
        });

        dumpPath[depositPID].push(defaultDumpRoute);
        dumpPathExistence[depositPID] = false;
    }

    // Initialize route arrays with default values
    function _initializeRoutes() internal {
        // Token to convert token route
        tokenToconvertToken.push(IModifiedRouter.Route({
            from: address(token),
            to: address(convertToken),
            stable: true
        }));

        // Token to pool token0 route
        tokenTopooltoken0.push(IModifiedRouter.Route({
            from: address(token),
            to: address(pooltoken0),
            stable: true
        }));
    }

    // Helper function to update pool token routes
    function _updatePoolTokenRoutes() internal {
        // Clear existing routes
        while(pooltoken0Topooltoken1.length > 0) {
            pooltoken0Topooltoken1.pop();
        }

        while(pooltoken1Topooltoken0.length > 0) {
            pooltoken1Topooltoken0.pop();
        }

        // Add new routes
        pooltoken0Topooltoken1.push(IModifiedRouter.Route({
            from: address(pooltoken0),
            to: address(pooltoken1),
            stable: true
        }));

        pooltoken1Topooltoken0.push(IModifiedRouter.Route({
            from: address(pooltoken1),
            to: address(pooltoken0),
            stable: true
        }));
    }

    function harvest() public {
        require(msg.sender == harvester || msg.sender == owner, "harvest: no permission");
        _claimAllRewards();
        _convertRewards();
    }

    function harvestandcompound() public {
        require(msg.sender == harvester || msg.sender == owner, "harvestandcompound: no permission");
        _claimAllRewards();
        compoundRewards();
    }

    function addPool(uint256 pid) public {
        require(msg.sender == owner, "addPool: owner only");

        // Check for duplicated PIDs
        uint256 length = pools.length;
        bool poolExists = false;
        for (uint256 i = 0; i < length; ++i) {
            if(pools[i] == pid) poolExists = true;
        }

        if(!poolExists) pools.push(pid);
    }

    function stakeall(uint256 pid) public {
        require(msg.sender == owner, "harvest: no permission");
        (address want) = masterchef.poolInfo(pid);
        IERC20 wantToken = IERC20(want);
        uint256 amount = wantToken.balanceOf(address(msg.sender));
        wantToken.transferFrom(address(msg.sender), address(this), amount);

        addPool(pid); // Always add pool when staking in case you forget to add manually.
        _deposit(pid);
    }

    function stake(uint256 pid, uint256 amount) public {
        require(msg.sender == owner, "harvest: no permission");
        require(amount > 0, "Stake amount must be larger than 0");
        (address want) = masterchef.poolInfo(pid);
        IERC20 wantToken = IERC20(want);
        wantToken.transferFrom(address(msg.sender), address(this), amount);

        addPool(pid); // Always add pool when staking in case you forget to add manually.
        _deposit(pid);
    }

    function deposit(uint256 pid) public {
        require(msg.sender == harvester || msg.sender == owner, "deposit: no permission");
        _deposit(pid);
    }

    function _deposit(uint256 pid) internal {
        (address want) = masterchef.poolInfo(pid);

        IERC20 wantToken = IERC20(want);
        uint256 amount = wantToken.balanceOf(address(this));
        if(amount > 0){
            wantToken.approve(address(masterchef), amount);
            masterchef.deposit(pid, amount);
        }
    }

    function _deposit(uint256 pid, uint256 _amount) internal {
        (address want) = masterchef.poolInfo(pid);

        IERC20 wantToken = IERC20(want);
        if(_amount > 0){
            wantToken.approve(address(masterchef), _amount);
            masterchef.deposit(pid, _amount);
        }
    }

    //withdraw staked tokens from masterchef
    function withdraw(uint256 pid, uint256 amount) public {
        require(msg.sender == owner, "withdraw: owner only");
        masterchef.withdraw(pid, amount);
    }

    function withdrawall(uint256 pid, bool convert) public {
        require(msg.sender == owner, "withdraw all: owner only");
        (uint256 amount,) = masterchef.userInfo(pid, address(this));
        masterchef.withdraw(pid, amount);
        (address want) = masterchef.poolInfo(pid);
        inCaseTokensGetStuck(want);
        if (convert == false) {
            inCaseTokensGetStuck(address(token));
            return;
        }
        convertRewards();
        inCaseTokensGetStuck(address(convertToken));
    }

    // Withdraw from MC, remove liquidity and send back to the owner.
    function withdrawAndRemove(uint256 pid) public {
        require(msg.sender == owner, "withdrawAndRemove: owner only");
        (uint256 amount,) = masterchef.userInfo(pid, address(this));
        masterchef.withdraw(pid, amount);
        removeLiquidity(pid, true);
        convertRewards();
        inCaseTokensGetStuck(address(convertToken));
    }

    // Withdraw from MC, remove liquidity and dump tokens to convertToken.
    function withdrawRemoveDump(uint256 pid, uint256 percentage) public {
        require(msg.sender == owner, "withdrawRemoveDump: owner only");
        require(percentage > 0 && percentage <= 100, "Percentage must be between 0 and 100");

        (uint256 amount,) = masterchef.userInfo(pid, address(this));
        masterchef.withdraw(pid, amount * percentage / 100);
        removeLiquidity(pid, false);

        dumpcoins(pid);
        convertRewards();
        inCaseTokensGetStuck(address(convertToken));
    }

    function emergencyWithdrawAll() public {
        require(msg.sender == owner, "emergencyWithdrawAll: owner only");
        for (uint256 i = 0; i < pools.length; i++) {
            masterchef.emergencyWithdraw(pools[i]);
        }
    }

    function emergencyWithdraw(uint256 pid) public {
        require(msg.sender == owner, "emergencyWithdraw: owner only");
        masterchef.emergencyWithdraw(pid);
    }

    function withdrawEverythingToWallet() public {
        require(msg.sender == owner, "widhrawEverythingToWallet: owner only");
        for (uint256 i = 0; i < pools.length; i++) {
            masterchef.emergencyWithdraw(pools[i]);
            (address want) = masterchef.poolInfo(pools[i]);
            inCaseTokensGetStuck(want);
        }
    }

    function claimAllRewards() public {
        require(msg.sender == harvester || msg.sender == owner, "claimAllRewards: no permission");
        _claimAllRewards();
    }

    function _claimAllRewards() internal {
        for (uint256 i = 0; i < pools.length; i++) {
            _claimRewards(pools[i]);
        }
    }

    function claimRewards(uint256 pid) public {
        require(msg.sender == harvester || msg.sender == owner, "claimRewards: no permission");
        _claimRewards(pid);
    }

    function _claimRewards(uint256 pid) internal {
        masterchef.deposit(pid, 0);
    }

    function convertRewards() public {
        require(msg.sender == harvester || msg.sender == owner, "convertRewards: no permission");
        _convertRewards();
    }

    function _convertRewards() internal {
        uint256 balance = token.balanceOf(address(this));
        if (balance > 0 && address(token) != address(convertToken)) {
            router.swapExactTokensForTokens(
                balance,
                0,
                tokenToconvertToken,
                address(this)
            );
        }
    }

    function compoundRewards() public {
        require(msg.sender == harvester || msg.sender == owner, "convertRewards: no permission");

        if (compoundLP == true) _compoundRewardsLP();
        else _compoundRewards();
    }

    function _compoundRewardsLP() internal {
        uint256 balance = token.balanceOf(address(this));
        if (balance > 0) {
            if (address(token) == address(pooltoken0)) {
                router.swapExactTokensForTokens(
                    balance / 2,
                    0,
                    pooltoken0Topooltoken1,
                    address(this)
                );
            } else if (address(token) == address(pooltoken1)) {
                router.swapExactTokensForTokens(
                    balance / 2,
                    0,
                    pooltoken1Topooltoken0,
                    address(this)
                );
            } else {
                // For most compatibility, route token => pooltoken0 => pooltoken1
                router.swapExactTokensForTokens(
                    balance,
                    0,
                    tokenTopooltoken0,
                    address(this)
                );

                router.swapExactTokensForTokens(
                    pooltoken0.balanceOf(address(this)) / 2,
                    0,
                    pooltoken0Topooltoken1,
                    address(this)
                );
            }
            router.addLiquidity(
                address(pooltoken0),
                address(pooltoken1),
                pooltoken0.balanceOf(address(this)),
                pooltoken1.balanceOf(address(this)),
                0,
                0,
                address(this),
                block.timestamp
            ); // Add liquidity
            _deposit(depositPID);
        }
    }

    function _compoundRewards() internal {
        uint256 _balance = 0;
        uint256 balance = token.balanceOf(address(this));
        if (balance > 0) {
            uint256 balance_before = pooltoken0.balanceOf(address(this));
            if (address(token) != address(pooltoken0)) {
                router.swapExactTokensForTokens(
                    balance,
                    0,
                    tokenTopooltoken0,
                    address(this)
                );
                _balance = pooltoken0.balanceOf(address(this)) - balance_before;
            } else {
                _balance = balance_before;
            }
            _deposit(depositPID, _balance);
        }
    }

    function removeLiquidity(uint256 pid, bool retrieve) public {
        require(msg.sender == owner, "removeLiquidity: owner only");

        (address lptoken) = masterchef.poolInfo(pid);
        if (isLP(lptoken) == false) {
            if (retrieve == true) inCaseTokensGetStuck(lptoken);
            return;
        }

        address token0 = Pair(lptoken).token0();
        address token1 = Pair(lptoken).token1();

        _removeLiquidity(lptoken, token0, token1);

        if (retrieve == true) {
            inCaseTokensGetStuck(token0);
            inCaseTokensGetStuck(token1);
        }
    }

    function _removeLiquidity(address lptoken, address token0, address token1) internal {
        IERC20 lpToken = IERC20(lptoken);
        uint256 liquidity = lpToken.balanceOf(address(this));
        require(liquidity > 0, "_removeLiquidity: balance must be > 0");

        lpToken.approve(address(router), liquidity);

        router.removeLiquidity(
            token0,
            token1,
            liquidity,
            0,
            0,
            address(this),
            block.timestamp);
    }

    // Dump token0 and token1 of the LP token of the pid to convertToken.
    // Only works if dumpPath[pid] has been defiend.
    function dumpcoins(uint256 pid) public {
        require(msg.sender == owner, "dumpcoins: owner only");
        require(dumpPathExistence[pid] == true, "Token dump path not defined for this pid");

        (address lptoken) = masterchef.poolInfo(pid);
        if (compoundLP == true) _dumpLP(pid, lptoken);
        else _dumptoken(pid, lptoken);
    }

    function _dumpLP(uint256 pid, address lptoken) internal {
        // Dump token0 and token1 of an LP token to convertToken

        address token0;
        address token1;

        if (Pair(lptoken).token1() == address(osonic) || Pair(lptoken).token1() == address(0)) {
            token1 = Pair(lptoken).token0();
            token0 = Pair(lptoken).token1();
        } else {
            token0 = Pair(lptoken).token0();
            token1 = Pair(lptoken).token1();
        }

        if ((address(token1) != address(token)) && (address(token1) != address(convertToken))) { // token will get liquidated using _convertRewards below.
            // Update token1Totoken0 to include the correct route
            while(token1Totoken0.length > 0) {
                token1Totoken0.pop();
            }

            token1Totoken0.push(IModifiedRouter.Route({
                from: address(token1),
                to: address(token0),
                stable: true
            }));

            router.swapExactTokensForTokens(
                IERC20(token1).balanceOf(address(this)),
                0,
                token1Totoken0,
                address(this)
            );
        }

        if ((address(token0) != address(token)) && (address(token0) != address(convertToken))) { // token will get liquidated using _convertRewards below.
            router.swapExactTokensForTokens(
                IERC20(token0).balanceOf(address(this)),
                0,
                dumpPath[pid],
                address(this)
            );
        }
    }

    function _dumptoken(uint256 pid, address lptoken) internal {
        // Dump a token to convertToken
        router.swapExactTokensForTokens(
            IERC20(lptoken).balanceOf(address(this)),
            0,
            dumpPath[pid],
            address(this)
        );
    }

    function inCaseTokensGetStuck(
        address _token,
        uint256 _amount
    ) public {
        require(msg.sender == owner, "inCaseTokensGetStuck: owner only");
        IERC20(_token).transfer(msg.sender, _amount);
    }

    function inCaseTokensGetStuck(
        address _token
    ) public {
        require(msg.sender == owner, "inCaseTokensGetStuck: owner only");
        IERC20 t = IERC20(_token);
        uint256 balance = t.balanceOf(address(this));
        t.transfer(msg.sender, balance);
    }

    // *******************
    // Emergency functions
    // *******************

    function executeTransaction(address target, uint value, bytes memory data) public payable returns (bytes memory) {
        require(msg.sender == owner, "executeTransaction: owner only");
        (bool success, bytes memory returnData) = target.call{value:value}(data);
        require(success, "Reverted.");
        return returnData;
    }

    function executeDelegateTransaction(address target, bytes memory data) public payable returns (bytes memory) {
        require(msg.sender == owner, "executeTransaction: owner only");
        (bool success, bytes memory returnData) = target.delegatecall(data);
        require(success, "Reverted.");
        return returnData;
    }

    // ********************
    // Governance functions
    // ********************

    function setrouter(IModifiedRouter _router) public {
        require(msg.sender == owner);
        router = _router;
        token.approve(address(router), type(uint256).max);
        pooltoken0.approve(address(router), type(uint256).max);
        pooltoken1.approve(address(router), type(uint256).max);
    }

    function changeOwner(address _owner) public {
        require(msg.sender == owner);
        proposedOwner = _owner;
    }

    function acceptOwnership() public {
        require(msg.sender == proposedOwner);
        owner = proposedOwner;
    }

    function setHarvester(address _harvester) public {
        require(msg.sender == owner);
        harvester = _harvester;
    }

    function setDepositPID(uint256 _depositPID) public {
        require(msg.sender == owner);
        depositPID = _depositPID;
    }

    function setToken(address _token) public {
        require(msg.sender == owner);
        token = IERC20(_token);
        token.approve(address(router), type(uint256).max);

        // Update routes involving token
        _updateTokenRoutes();
    }

    function _updateTokenRoutes() internal {
        // Clear existing routes
        while(tokenToconvertToken.length > 0) {
            tokenToconvertToken.pop();
        }

        while(tokenTopooltoken0.length > 0) {
            tokenTopooltoken0.pop();
        }

        // Add new routes
        tokenToconvertToken.push(IModifiedRouter.Route({
            from: address(token),
            to: address(convertToken),
            stable: true
        }));

        tokenTopooltoken0.push(IModifiedRouter.Route({
            from: address(token),
            to: address(pooltoken0),
            stable: true
        }));
    }

    function setConvertToken(address _token) public {
        require(msg.sender == owner);
        convertToken = IERC20(_token);

        // Update routes involving convertToken
        _updateConvertTokenRoutes();
    }

    function _updateConvertTokenRoutes() internal {
        // Clear existing routes
        while(tokenToconvertToken.length > 0) {
            tokenToconvertToken.pop();
        }

        // Add new routes
        tokenToconvertToken.push(IModifiedRouter.Route({
            from: address(token),
            to: address(convertToken),
            stable: true
        }));
    }

    function setPoolTokens(address _pooltoken0, address _pooltoken1) public {
        require(msg.sender == owner);

        if (address(pooltoken0) != _pooltoken0) {
            pooltoken0 = IERC20(_pooltoken0);

            // Update routes involving pooltoken0
            while(tokenTopooltoken0.length > 0) {
                tokenTopooltoken0.pop();
            }

            tokenTopooltoken0.push(IModifiedRouter.Route({
                from: address(token),
                to: address(pooltoken0),
                stable: true
            }));

            pooltoken0.approve(address(router), type(uint256).max);
        }

        if (address(pooltoken1) != _pooltoken1) {
            pooltoken1 = IERC20(_pooltoken1);
            pooltoken1.approve(address(router), type(uint256).max);
        }

        // Update LP related routes if compoundLP is true
        if (compoundLP) {
            _updatePoolTokenRoutes();
        }
    }

    function setTokenToconvertToken(IModifiedRouter.Route[] calldata _tokenToconvertToken) public {
        require(msg.sender == owner);

        // Clear existing routes
        while(tokenToconvertToken.length > 0) {
            tokenToconvertToken.pop();
        }

        // Add new routes
        for(uint i = 0; i < _tokenToconvertToken.length; i++) {
            tokenToconvertToken.push(_tokenToconvertToken[i]);
        }
    }

    function setTokenTopooltoken0(IModifiedRouter.Route[] calldata _tokenTopooltoken0) public {
        require(msg.sender == owner);

        // Clear existing routes
        while(tokenTopooltoken0.length > 0) {
            tokenTopooltoken0.pop();
        }

        // Add new routes
        for(uint i = 0; i < _tokenTopooltoken0.length; i++) {
            tokenTopooltoken0.push(_tokenTopooltoken0[i]);
        }
    }

    function setDumpPath(uint256 pid, IModifiedRouter.Route[] calldata _dumpPath) public {
        require(msg.sender == owner);

        // Clear existing routes
        while(dumpPath[pid].length > 0) {
            dumpPath[pid].pop();
        }

        // Add new routes
        for(uint i = 0; i < _dumpPath.length; i++) {
            dumpPath[pid].push(_dumpPath[i]);
        }

        dumpPathExistence[pid] = true;
    }

    function setCompoundLP(bool _compoundLP) public {
        require(msg.sender == owner, "setCompoundLP: owner only");

        (address lptoken) = masterchef.poolInfo(depositPID);
        (bool success, bytes memory data) = lptoken.staticcall(abi.encodeWithSignature("getReserves()"));
        require(success && data.length == 96, "depostidPID token is not a Uniswap LP token. Did you update depositPID?");

        compoundLP = _compoundLP;

        // Update LP related routes if compoundLP is true
        if (compoundLP) {
            _updatePoolTokenRoutes();
        }
    }
 
    function setMC(address _mc) public {
        require(msg.sender == owner, "setMC: owner only");
        masterchef = Masterchef(_mc);
    }

    function clearPools() public {
        require(msg.sender == owner, "clearPools: owner only");
        delete pools;
    }

    // **************
    // View functions
    // **************
    function isLP(address addr) public view returns (bool) {
        (bool success, bytes memory data) = addr.staticcall(abi.encodeWithSignature("getReserves()"));
        return (success && data.length == 96);
    }
}