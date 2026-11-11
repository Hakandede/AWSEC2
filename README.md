# AWSEC2

`aws-wrapper.sh` is a small Bash front end for the EC2 instance that runs my
OpenVPN server (and my website). It started as a cost saver, starting the box
only when I needed the VPN and stopping it afterwards. Once the same box began
serving the website it moved to running 24/7 behind an Elastic IP.

## What it does

| Command | |
|---|---|
| `aws-wrapper.sh` | Shows the banner and state, offers to start a stopped instance, syncs the OpenVPN profile, checks the website, opens OpenVPN Connect |
| `aws-wrapper.sh status` | Instance state, public IP and an HTTP health check |
| `aws-wrapper.sh start` | Starts the instance, retrying through `InsufficientInstanceCapacity` |
| `aws-wrapper.sh stop` | Stops it after confirmation |
| `aws-wrapper.sh ssh [cmd]` | Logs in with **EC2 Instance Connect**: pushes a throwaway public key that is valid for 60 seconds, so no long-lived key pair is needed |

## Setup

Requires the AWS CLI v2 with credentials that can describe, start and stop the
instance and call `ec2-instance-connect:SendSSHPublicKey`.

```bash
mkdir -p ~/.config
cp aws-wrapper.conf.example ~/.config/aws-wrapper.conf   # then edit it
./aws-wrapper.sh status
```

Written to run from WSL, so it can open the Windows OpenVPN Connect client and
edit its profile.

## History

The first version kept a dynamic public IP, so on every start it rewrote the
OpenVPN profile and updated a Cloudflare DNS record through the API. Moving to
an Elastic IP removed both steps and the API credentials that came with them.
