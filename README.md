# How to Migrate Jenkins from Systemd to Docker

This guide shows you how to migrate your existing Jenkins installation from systemd to Docker using Ansible automation, while preserving all your data and configurations.

## Prerequisites

Before starting, ensure you have:

- **Linux server** running Ubuntu 20.04+ (or similar)
- **Existing Jenkins** running via systemd service
- **Jenkins admin access** with API token
- **Ansible 2.14+** installed with sudo privileges
- **Internet connection** for downloading Docker and dependencies

## Step 1: Get Your Jenkins API Token

1. Log into your Jenkins web interface
2. Go to **Your Username** → **Configure** → **API Token**
3. Click **Add new Token**, give it a name, and **Generate**
4. **Copy the token** - you'll need it in the next step

## Step 2: Configure Secure Credentials

**🔐 SECURITY UPDATE**: Credentials are now stored in an encrypted Ansible Vault for security.

### Set Up Your Encrypted Credentials

1. **Edit the encrypted vault file**:
```bash
ansible-vault edit vars/vault.yml
```

2. **Set your Jenkins credentials** (replace the CHANGE_ME values):
```yaml
---
# Jenkins API Credentials (Required)
vault_jenkins_migration_user: "your-jenkins-username"
vault_jenkins_migration_api_token: "your-api-token-from-step-1"

# Optional: Only if Jenkins uses HTTPS with a Java keystore directly
# (Not needed if using HTTP or behind a reverse proxy like Nginx/Apache)
# vault_jenkins_migration_keystore_password: "ssl-keystore-password"
```

3. **Save and exit** your editor

### Vault Password

**🔒 SECURITY UPDATE**: The vault has been secured with a strong, randomly-generated password.

The vault password has been saved to: `.vault_pass` (already in .gitignore)

**⚠️ IMPORTANT SECURITY STEPS**:

1. **Save the password securely** (password manager, secure vault, etc.):
```bash
cat .vault_pass  # Copy this password to a secure location
```

2. **Keep the .vault_pass file secure** (it has 600 permissions and is in .gitignore)

3. **To change the vault password in the future**:
```bash
ansible-vault rekey vars/vault.yml
```

**Never commit the vault password to version control!**

## Step 3: Install Required Dependencies

```bash
# Install Ansible collections
ansible-galaxy collection install -r requirements.yml

# Verify installation
ansible-galaxy collection list community.docker
```

## Step 4: Run the Migration

### Execute the Migration

Run the migration playbook with vault password:

```bash
ansible-playbook migrate.yml --ask-vault-pass
```

**🔑 You'll be prompted for the vault password** (check `.vault_pass` or your secure storage)

This will:
1. **Validate** your configuration and credentials
2. **Discover** your Jenkins installation and settings
3. **Backup** critical systemd configuration files
4. **Extract** your current Jenkins configuration via API
5. **Setup** Docker environment and validate configurations
6. **Migrate** by stopping systemd and starting Docker
7. **Verify** the migration was successful

### Alternative: Store Vault Password in File

For automation, create a password file:
```bash
# Store your secure password in a file (replace with your actual password)
echo "your-secure-vault-password" > .vault_pass
chmod 600 .vault_pass
ansible-playbook migrate.yml --vault-password-file .vault_pass

# IMPORTANT: Add .vault_pass to .gitignore to prevent accidental commits
echo ".vault_pass" >> .gitignore
```

## Step 5: Verify Migration Success

### Check Jenkins is Running

```bash
# Check containers are running
docker compose -f /opt/jenkins-docker/docker-compose.yml ps

# Check Jenkins logs
docker logs jenkins

# Access Jenkins web interface (same URL as before)
# Your Jenkins should be accessible at the same address
```

### Verify Your Data

- ✅ All jobs should be present
- ✅ All plugins should be installed  
- ✅ All configurations should be preserved
- ✅ Build history should be intact

## Step 6: Post-Migration Configuration (Optional)

### Update JCasC Configuration

After migration, you can modify Jenkins using Configuration as Code:

1. **Edit** `/opt/jenkins-docker/jenkins.yaml`
2. **Reload** configuration:

```bash
# Method 1: Via API
curl -X POST "http://localhost:8080/reload-configuration-as-code/"

# Method 2: Via Ansible
ansible-playbook migrate.yml --tags jcasc-reload
```

### Manage Container Updates

Watchtower automatically updates your Jenkins container daily at 4 AM.

## Troubleshooting

### If Migration Fails

**Don't panic!** Your original Jenkins is preserved. You can:

1. **Check logs**: `docker logs jenkins`
2. **Rollback**: Run the rollback playbook to restore systemd service

```bash
ansible-playbook rollback.yml
```

### Common Issues

| Problem | Solution |
|---------|----------|
| "API token invalid" | Regenerate token in Jenkins, update encrypted vault: `ansible-vault edit vars/vault.yml` |
| "Port 8080 in use" | Stop other services using port 8080 first |
| "Permission denied" | Ensure you have sudo access |
| "Docker not found" | Let the playbook install Docker automatically |
| "Jenkins not responding" | Wait 2-3 minutes for startup, then check `docker logs jenkins` |

## How to Rollback

If you need to return to systemd Jenkins:

```bash
ansible-playbook rollback.yml
```

This will:
- Stop Docker containers
- Re-enable systemd Jenkins service
- Start Jenkins via systemd
- Your original configuration is fully restored

## Files Created During Migration

The migration creates these files in `/opt/jenkins-docker/`:

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Container definitions (Jenkins + Watchtower) |
| `jenkins.yaml` | Your Jenkins configuration as code |
| `plugins.txt` | List of installed plugins |
| `.env` | **Sensitive environment variables** (permissions: 600) |
| `backup/` | Backup of original systemd configurations |

### Environment Variables (.env)

The `.env` file contains sensitive values like:
- `CASC_RELOAD_TOKEN` - Token for reloading Jenkins configuration
- `JENKINS_HTTPS_KEYSTORE_PASSWORD` - SSL keystore password (if using HTTPS)

**Security Notes:**
- The `.env` file has restricted permissions (600)
- It's automatically excluded from version control
- Store a backup of these values in a secure password manager
- To rotate tokens, edit `.env` and restart the container

## Security Features

- 🔒 **Encrypted credentials**: All sensitive data stored in Ansible Vault
- 🔒 **Input validation**: Configuration validated before migration starts
- 🔒 **Docker socket security**: Disabled by default with clear warnings when enabled
- 🔒 **Data preservation**: Original `JENKINS_HOME` mounted safely
- 🔒 **Error handling**: Specific error conditions instead of broad ignores
- 🔒 **Backup system**: Original configurations backed up before migration
- 🔒 **Rollback capability**: Complete restoration to original state
- 🔒 **No hardcoded secrets**: All magic numbers replaced with named constants

## Advanced Configuration

### Run on Remote Hosts

By default, the playbook runs on localhost. To run on remote hosts, use an inventory:

```bash
# Create inventory file
echo "[jenkins_servers]" > my-hosts.yml
echo "jenkins-server-1.example.com" >> my-hosts.yml

# Run with custom inventory
ansible-playbook -i my-hosts.yml migrate.yml --extra-vars "target_hosts=jenkins_servers"
```

### Disable Docker Socket Access (Recommended)

For maximum security, Jenkins containers run without Docker socket access by default. If you need Docker-in-Docker for agents:

```yaml
# In vars/main.yml - Enable only if needed for Docker agents
jenkins_migration_enable_docker_socket: true
```

### Customize Resource Limits

```yaml
# In vars/main.yml - Adjust container resources
jenkins_migration_max_ram_percentage: "90"  # Use 90% of system RAM
```

### Change Migration Directory

```yaml
# In vars/main.yml - Custom Docker directory
jenkins_migration_docker_dir: "/custom/path/jenkins-docker"
```

## What This Migration Does NOT Do

- ❌ **Modify Jenkins configuration** - Your Jenkins stays exactly as configured
- ❌ **Change Jenkins URL** - Same address as before
- ❌ **Alter job configurations** - All jobs preserved unchanged  
- ❌ **Remove original data** - `JENKINS_HOME` is completely preserved
- ❌ **Change user access** - All users and permissions preserved

## Support

If you encounter issues:

1. **Check syntax**: `ansible-playbook --syntax-check migrate.yml`
2. **Validate YAML**: `yamllint migrate.yml`
3. **Run with verbose**: `ansible-playbook migrate.yml -vvv`
4. **Review logs**: Check both Ansible output and `docker logs jenkins`

Your Jenkins data is always safe - the migration only changes how Jenkins runs, not what it contains.