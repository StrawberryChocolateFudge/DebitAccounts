import { ethers } from "hardhat";

//This will do a full deploy!

async function main() {
  const verifierFactory = await ethers.getContractFactory(
    "contracts/PaymentIntentVerifier.sol:Verifier",
  );
  const Verifier = await verifierFactory.deploy();
  await Verifier.deployed().then(async () => {
    console.log("Verifier contract is deployed to ", Verifier.address);

    const VirtualAccountsFactory = await ethers.getContractFactory(
      "VirtualAccounts",
    );

    const virtualAccounts = await VirtualAccountsFactory.deploy(
      Verifier.address,
    );

    await virtualAccounts.deployed().then(async () => {
      console.log(
        "Virtual Accounts contract is deployed to : ",
        virtualAccounts.address,
      );

      const ConnectedWalletsFactory = await ethers.getContractFactory(
        "ConnectedWallets",
      );
      const connectedWallets = await ConnectedWalletsFactory.deploy(
        Verifier.address,
      );
      await connectedWallets.deployed();

      console.log(
        "Connected Wallets contract is deployed to: ",
        connectedWallets.address,
      );
    });
  });
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

// DONAU TESTNET ADDRESSES: (redeployed with finalized circuit)
// Verifier contract is deployed to  0x6d387f7b1f062e82B29aC4185e547a3fE4805fC7
// Virtual Accounts contract is deployed to :  0xF75515Df5AC843a8B261E232bB890dc2F75A4066
// Connected Wallets contract is deployed to:  0x9c85da9E45126Fd45BC62656026A2E7226bba239

//BTT MAINNET ADDRESSES:

// Verifier contract is deployed to  0x5e93788886D8712C0cDe623fB22dCf979ed07724
// Virtual Accounts contract is deployed to :  0xc4Cf42D5a6F4F061cf5F98d0338FC5913b6fF581
// Connected Wallets contract is deployed to:  0xF9962f3C23De4e864E56ef29125D460c785905c6