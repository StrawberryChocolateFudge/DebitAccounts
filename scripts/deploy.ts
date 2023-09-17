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
        "0x22c025aa2009DfAbbc10F5262512A999D2a73E0d",
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

// DONAU TESTNET ADDRESSES: (redeployed to use getAccount view function)
// Verifier contract is deployed to  0x22c025aa2009DfAbbc10F5262512A999D2a73E0d
// Virtual Accounts contract is deployed to :  0x870B0E3cf2c556dda20D3cB39e87145C21e8C023
// Connected Wallets contract is deployed to:  0xaB9ADa67294C7f5F4690f23CEaEc4Ec6c4B14976
