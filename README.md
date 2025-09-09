# Jenkins Migration Tool

**Lift-and-shift Jenkins from systemd to Docker** with zero downtime and complete data preservation.

## 🚀 Quick Start

```bash
# Configure Jenkins API access (optional - can auto-detect most settings)
vi jenkins-migrate.conf

# Run migration (requires sudo for systemctl operations)
sudo ./jenkins-migrate.sh
```

**What happens:** Jenkins data stays exactly the same, just switches from systemd to Docker runtime with automated updates and better disaster recovery.

## Features

- **Lift & Shift**: Preserves all users, jobs, and data via `$JENKINS_HOME` volume mount
- **Auto-Docker**: Installs Docker CE automatically if missing
- **JCasC Live**: Generates Configuration as Code from live Jenkins schema
- **Watchtower**: Daily 4am updates for security patches
- **Config Generation**: Uses `envsubst` for Docker configuration and live schema for JCasC

## Configuration

Edit `jenkins-migrate.conf`:

```bash
JENKINS_URL="http://localhost:8080"
JENKINS_USER="your_username" 
JENKINS_API_TOKEN="your_api_token"
```

## 📖 Step-by-Step Migration Walkthrough

When you run `sudo ./jenkins-migrate.sh`, here's exactly what happens:

### **Phase 1: Pre-flight Validation** ✈️
```
🔍 Jenkins Migration Tool v1.0
==========================================

⚡ Phase 1: Environment Validation
├─ ✅ Running as root (sudo detected)
├─ ✅ Jenkins user found: jenkins (uid=112, gid=117)
├─ ✅ Jenkins user in docker group
├─ ✅ Docker daemon running (version 24.0.6)
├─ ✅ Docker Compose available (v2.21.0)
└─ ✅ All prerequisites met

🔍 Phase 2: Discovery & Detection
├─ 🏠 Jenkins Home: /var/lib/jenkins (87GB used)
├─ 👤 Jenkins User: 112:117 (jenkins:jenkins)
├─ 🌐 Jenkins URL: http://localhost:8080
├─ 🔌 Agent Port: 50000
├─ ⚙️  Service Status: active (running)
└─ 📦 Plugins Found: 47 active plugins detected
```

### **Phase 2: Configuration Generation** 🛠️
```
⚙️  Phase 3: Generating Docker Configuration
├─ 📁 Creating /opt/jenkins-docker/ (owned by jenkins:jenkins)
├─ 🐳 Generating docker-compose.yml from template...
├─ 🔌 Extracting plugins via Jenkins API...
│   └─ ✅ 47 plugins written to plugins.txt
├─ ⚙️  Generating jenkins.yaml (JCasC) from live schema...
└─ ✅ All configuration files generated
```

### **Phase 3: Service Transition** 🔄
```
🔄 Phase 4: Service Migration
├─ ⏹️  Stopping systemd Jenkins service...
├─ 🚫 Disabling systemd auto-start...
└─ 🐳 Starting Docker containers...

     ┌─────────┐         ┌─────────┐
     │systemd  │  ════►  │ Docker  │
     │Jenkins  │         │Jenkins  │  
     └─────────┘         └─────────┘
        (OFF)              (READY)
```

### **Phase 4: Health Verification** 🏥
```
🏥 Phase 5: Health Check & Verification
├─ 🌐 Testing http://localhost:8080/login...
├─ 🔍 Verifying Jenkins home mount...
├─ 👥 Verifying user data preserved...
└─ ✅ Migration verification complete

🎉 SUCCESS! Jenkins Migration Complete!
```

### **Migration Summary**
```
    BEFORE                    AFTER
┌─────────────┐          ┌─────────────┐
│   systemd   │          │   Docker    │
│  ┌───────┐  │   ════►  │  ┌───────┐  │
│  │Jenkins│  │          │  │Jenkins│  │
│  │ :8080 │  │          │  │ :8080 │  │
│  └───┬───┘  │          │  └───┬───┘  │
│      │      │          │      │      │
│ /var/lib/   │          │ /var/lib/   │ 
│  jenkins    │          │  jenkins    │
└─────────────┘          └─────┬───────┘
                               │
                         ┌─────────┐
                         │Watchtower│
                         │ (4am)   │
                         └─────────┘

🎯 Same Jenkins, Same Data, Modern Platform!
```

**Result:** Same URL, same login, same everything - but now with automated updates and better DR!

## File Structure

```
├── jenkins-migrate.sh          # Main script
├── jenkins-migrate.conf        # Configuration
├── lib/                        # Core libraries
├── modules/                    # Feature modules
├── templates/                  # Config templates
└── scripts/                    # Helper scripts
```

## User Preservation

**All existing users are preserved** - no admin password needed.

Your current user and API token work exactly the same after migration via `$JENKINS_HOME` volume mount.

## Docker Integration

- **Official Installation**: Follows Ubuntu Docker documentation
- **Docker Compose v2**: Modern format without deprecated version field
- **Health Checks**: Built-in container monitoring
- **Auto-Start**: Docker daemon started automatically

## Watchtower Updates

- **Schedule**: Daily at 4:00 AM
- **Target**: Jenkins container only
- **Cleanup**: Removes old images automatically
- **Future-Proof**: Ready for JDK 21 when Jenkins LTS switches

## Rollback

```bash
sudo ./jenkins-migrate.sh --rollback
```

Restores systemd Jenkins service and stops Docker containers.

## Requirements

- Ubuntu 18.04+
- 2GB+ RAM
- sudo access
- Existing Jenkins systemd service

Docker will be installed automatically if missing.

## 📦 Post-Migration: Plugin Management (Official 2025 Method)

The migration generates a **custom Jenkins Docker image** with `plugins.txt` support using the **official Jenkins Docker approach**:

### Initial Migration Experience
- ✅ **Zero changes needed** - Existing plugins work immediately via volume mount
- ✅ **No rebuilding required** - All plugins preserved in `${JENKINS_HOME}`  
- ✅ **Same lift-and-shift experience** - Everything works as before

### Modern Plugin Management (Infrastructure as Code)
```bash
# View extracted plugins (generated from your current installation)
cat plugins.txt

# Example plugins.txt format:
git:4.8.3
workflow-aggregator:2.6
pipeline-stage-view:2.25
build-timeout:1.27
```

### Adding New Plugins
```bash
# 1. Edit plugins.txt to add new plugins
vi plugins.txt

# Add new plugin with version
echo "blueocean:1.25.2" >> plugins.txt

# 2. Rebuild Jenkins image with new plugins
docker compose build jenkins

# 3. Restart with updated image
docker compose up -d --force-recreate jenkins
```

### Updating Plugin Versions
```bash
# 1. Update specific plugin versions in plugins.txt
sed -i 's/git:4.8.3/git:4.8.4/' plugins.txt

# 2. Rebuild and restart
docker compose build jenkins
docker compose up -d --force-recreate jenkins

# 3. Monitor plugin installation
docker logs -f jenkins
```

### JCasC Plugin Configuration
```bash
# Plugin-specific settings go in JCasC config
vi /var/lib/jenkins/casc_configs/jenkins.yaml

# Example: Configure Git plugin
unclassified:
  gitPlugin:
    globalConfigName: "Jenkins CI"
    globalConfigEmail: "jenkins@company.com"
```

### Plugin Rollback Strategy
```bash
# Backup current plugins.txt before changes
cp plugins.txt plugins.txt.backup

# If issues occur, restore and restart
mv plugins.txt.backup plugins.txt
docker compose restart jenkins
```

### Best Practices
- ✅ **Official Jenkins 2025 methodology** - Uses `build:` approach
- ✅ **Infrastructure as Code** - Version controlled plugins with git
- ✅ **Reproducible deployments** - Exact same environment every time
- ✅ **Git-based rollback** - Easy to revert plugin changes
- ✅ **No manual docker exec** - Pure Docker Compose workflow
- **Version Pin**: Always specify versions in plugins.txt (avoid `:latest`)
- **Test Changes**: Update staging environment first
- **Monitor Logs**: Watch `docker logs jenkins` during updates
- **JCasC First**: Configure plugins via JCasC when possible
- **Backup Config**: Version control your plugins.txt and jenkins.yaml


## Troubleshooting

General commands for inspecting the state of the new Dockerized Jenkins:

```bash
# View live logs from the Jenkins container
docker logs -f jenkins

# Check the status of all migration-related containers
docker compose -f /opt/jenkins-docker/docker-compose.yml ps

# Restart the Jenkins container
docker restart jenkins
```

### JCasC Validation Failures

If the migration fails during the "high-fidelity validation" step, it means the JCasC configuration generated from your old Jenkins is not compatible with the new Docker environment.

Here's how to debug this:

1.  **Examine the logs:** In the output of the `jenkins-migrate.sh` script, look for a section that starts with `--- DOCKER LOGS ---`. This section will contain the exact error message from Jenkins as it tried to load your configuration.

2.  **Identify the problem:** The error will typically be a `ConfigurationAsCodeException`. For example:
    *   `io.jenkins.plugins.casc.ConfiguratorException: 'credentials' is not a valid configuration for 'jenkins'`
    *   `No such DSL method 'pipelineTriggers' found among steps`

3.  **Fix the configuration:**
    *   The generated configuration file that needs editing is located at `/opt/jenkins-docker/jenkins.yaml`.
    *   You can open this file and try to fix the error based on the log message.
    *   After editing the file, you can quickly test your fix by running the validation script manually:
        ```bash
        sudo ./scripts/validate-casc.sh --docker /opt/jenkins-docker/jenkins.yaml
        ```
    *   Once the manual validation passes, you can re-run `sudo ./jenkins-migrate.sh`. The script will regenerate the configuration, so if the error was due to a problem in the `enhance_jcasc.py` script, you may need to fix the script itself.

---

**Ready?** Run `sudo ./jenkins-migrate.sh` to migrate your Jenkins to modern Docker infrastructure with automated updates.