// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract Setup {
    struct T {
        address superToken;
        address underlying; // address(0) for native SuperTokens
        bool isNative;
    }

    T[] public tokens;

    uint256 public immutable deployBlock;

    constructor() {
        deployBlock = block.number;
        tokens.push(T(0x00F22A2B5c40CE03FA4c96bA97605e5A40cC97D4, 0x079202AD852ccc46d8E73815f10Ff055049D3916, false)); // xCRE8R
        tokens.push(T(0x0485Df62669D0De09739eBccFbda20C9941cfDC2, 0x9246a5F10A79a5a939b0C2a75A3AD196aAfDB43b, false)); // BETSx
        tokens.push(T(0x0De929370aaB02aca9E766543421530e1e7FA566, 0xc3FdbadC7c795EF1D6Ba111e06fF8F16A20Ea539, false)); // ADDYx
        tokens.push(T(0x12c294107772b10815307c05989DABD71C21670e, 0x361A5a4993493cE00f61C32d4EcCA5512b82CE90, false)); // SDTx
        tokens.push(T(0x1305F6B6Df9Dc47159D12Eb7aC2804d4A33173c2, 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063, false)); // DAIx
        tokens.push(T(0x1963e341FF5a75C41ca5Ac400c828E636B70546E, 0x867D46fd484358A6f25655a705aa6AD804E6C6eB, false)); // DUSx
        tokens.push(T(0x1ADcA32B906883e474aEbcBA5708B41F3645f941, 0xcE899f26928a2B21c6a2Fddd393EF37c61dbA918, false)); // MOCAx
        tokens.push(T(0x229c5D13452dc302499B5C113768A0db0c9D5c05, 0x6863BD30C9e313B264657B107352bA246F8Af8e0, false)); // BPTx
        tokens.push(T(0x27e1e4E6BC79D93032abef01025811B7E4727e85, 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619, false)); // ETHx
        tokens.push(T(0x2c530aF1f088B836FA0dCa23c7Ea50E669508C4C, 0x6f7C932e7684666C9fd1d44527765433e01fF61d, false)); // MKRx
        tokens.push(T(0x2e12D38C6aa87cb68cE96C044b9A68dD98233Ceb, 0x92e918ea7aa872F91BF7EC9BcD248a5920C9f3CB, false)); // DBEATx
        tokens.push(T(0x3038B359240DFF5CCd42DfFd21f12b428034bE38, 0xE0B52e49357Fd4DAf2c15e02058DCE6BC0057db4, false)); // agEURx
        tokens.push(T(0x32cefdF2b3df73BDeBaA7cD3B0135B3A79d28Dcc, 0xB25e20De2F2eBb4CfFD4D16a55C7B395e8a94762, false)); // REQx
        tokens.push(T(0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3, address(0),                                 true));  // MATICx
        tokens.push(T(0x3d9CC088bD9357E5941b68d26d6D09254A69949d, 0xF501dd45a1198C2E1b5aEF5314A68B9006D842E0, false)); // MTAx
        tokens.push(T(0x4086eBf75233e8492F1BCDa41C7f2A8288c2fB92, 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6, false)); // WBTCx
        tokens.push(T(0x4bDe23854e7C81218463f6C8f331b46144E98eaC, 0x4e3Decbb3645551B8A19f0eA1678079FCB33fB4c, false)); // jEURx
        tokens.push(T(0x61A7B6F0A7737d9bD38fdeaf1d4160E16bf23043, 0x6002410dDA2Fb88b4D0dc3c1D562F7761191eA80, false)); // WORKx
        tokens.push(T(0x7D35eab5F5fdF6b458B18c29D0D61092835F9e99, 0x9b532fFa57631d77163BE75E965E6AdFc3b81510, false)); // SIGNALx
        tokens.push(T(0x8037Fa6312337DB96aa9a01499E94e2c04c47B11, 0x6f5ea5F39E625b317Dd4F710D32A29994A515383, false)); // VTRx
        tokens.push(T(0x84B2e92E08008c0081C8c21a35FdA4DdC5d21aC6, 0x361A5a4993493cE00f61C32d4EcCA5512b82CE90, false)); // sSDT
        tokens.push(T(0x8ef4F0C0753048a39B4Bc4eB3f545Fdae00618B7, 0x7d60F21072b585351dFd5E8b17109458D97ec120, false)); // sdam3CRVx
        tokens.push(T(0x9439198c4CCD67e658f4Bb936968362427Fef112, 0x70cd32C431C46990f341e554acb6CE91895BaAfA, false)); // NFXTx
        tokens.push(T(0x992446B88a7E62C7235Bd88108f44543C1887C1F, 0xa3Fa99A148fA48D14Ed51d610c367C61876997F1, false)); // MAIx
        tokens.push(T(0x9c37499ad25cE909d766A6b7De84Ad1B9eD75Ed0, 0x1BFD67037B42Cf73acF2047067bd4F2C47D9BfD6, false)); // WBTCx
        tokens.push(T(0xA794221D92d77490Ff319e95dA1461bdF2bd3953, 0xCD1F2F1a1d1ba631A06b957DB77BB9D7b13bF861, false)); // TDLx
        tokens.push(T(0xAb0b048E8b60EB9e8c7a2d46634326143393f2Ea, 0xE840B73E5287865EEc17d250bFb1536704B43B21, false)); // mUSDx
        tokens.push(T(0xAff1CE7832a1c7655803533DAb391920caFE467F, 0xF0Ae1EFdE60BAb0a830673747138F12367858e8D, false)); // FLOATx
        tokens.push(T(0xB63E38D21B31719e6dF314D3d2c351dF0D4a9162, 0xC25351811983818c9Fe6D8c580531819c8ADe90f, false)); // IDLEx
        tokens.push(T(0xbfaF6fDc0e0fECd8F82b763fB5db3a11418536E8, 0x22A1D4187f44EE5de1Fcd815BBa82b55909F1FBE, false)); // DECx
        tokens.push(T(0xC0Cd1F1b6164918965323eABf0A6a19838A19573, 0xf50D05A1402d0adAfA880D36050736f9f6ee7dee, false)); // INSTs
        tokens.push(T(0xCAa7349CEA390F89641fe306D93591f87595dc1F, 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174, false)); // USDCx
        tokens.push(T(0xcAE73e9EeE8a01b8B7F94b59133e3821F21470AB, 0xccBe9B810d6574701d324fD6DbE0A1b68f9d5bf7, false)); // STACKx
        tokens.push(T(0xcb5676568FeBb4e4f0DCa9407318836e7a973183, 0xf50D05A1402d0adAfA880D36050736f9f6ee7dee, false)); // INSTx
        tokens.push(T(0xDaB943C03f9e84795DC7BF51DdC71DaF0033382b, 0x0b3F868E0BE5597D5DB7fEB59E1CADBb0fdDa50a, false)); // SUSHIx
        tokens.push(T(0xe1cA10e6a10c0F72B74dF6b7339912BaBfB1f8B5, 0x580A84C73811E1839F75d86d75d88cCa0c241fF4, false)); // QIx
        tokens.push(T(0xe2b91fc5962a1daB21886dedab55999Af1041788, 0xaAa5B9e6c589642f98a1cDA99B9D024B8407285A, false)); // TITANx
        tokens.push(T(0xE2d04ab74eed9627c828B3fc10e5fC96FAE70348, 0xbD1463F02f61676d53fd183C2B19282BFF93D099, false)); // jCHFx
        tokens.push(T(0xe5FF13BaBb55644e1B1FDaE8d7B30626e544C12e, 0x8e915a77e301aD12Ad1f62012734cF7557Eee81a, false)); // BSTICKx
        tokens.push(T(0xEB5748f9798B11aF79F892F344F585E3a88aA784, 0xfdA25D931258Df948ffecb66b5518299Df6527C4, false)); // idleWETHx
        tokens.push(T(0xFBb291570DE4B87353B1e0f586Df97A1eD856470, 0x6AE7Dfc73E0dDE2aa99ac063DcF7e8A63265108c, false)); // JPYCx
    }

    function tokensLength() external view returns (uint256) {
        return tokens.length;
    }

    function isSolved() public view returns (bool) {
        for (uint256 i = 0; i < tokens.length; i++) {
            T memory t = tokens[i];
            if (t.isNative) {
                require(t.superToken.balance == 0, "native SuperToken not drained");
            } else {
                require(IERC20(t.underlying).balanceOf(t.superToken) == 0, "underlying not drained");
            }
        }
        return true;
    }
}
