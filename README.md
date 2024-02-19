# Getting Started

- Make sure all MikroTiks are plugged into a completely different router (this solve alot of the chicken and egg problems with having ip-ing setup)
- Factory Reset MikroTik (don't keep users, no default config, do not backup)
- Login (username: admin password: )
- Make new password
- Disconnect and sign in with new password
- Copy initialize script into terminal line by line
- Disconnect and sign in with new user and ip
- Run terraform init
- Change terraform cloud execution to local
- Run terraform import script
- Before any major firewall rule change, change all drop firewall rules to disabled.
- Run terraform apply
- Congrats! Your MikroTik is now managed by terraform
