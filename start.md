# Easy startup

Launch an Arch Linux ISO on your cloning workstation with your source and destination drive plugged in.
1) Set a password on your workstation
```bash
passwd
```

2) Get the IP of your workstation
```bash
ip addr
```

3) Connect through SSH
```bash
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@ip.address.of.target
```

4) Get keyring and install Git
```bash
pacman -Syu git
```

5) Clone the script
``` bash
git clone https://github.com/Muth-and-Company/clone
```

6) Set executable permissions
```bash
chmod +x clone.sh
```

6) Get your drive names
```bash
lsblk
```

7) Run the cloning script with your desired drives and arguments
```bash
sudo ./clone.sh --auto --recreate --fill /dev/sda /dev/nvme0n1
```

8) Check the README for post-cloning instructions