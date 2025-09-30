# jenkins_migration Role Technical Implementation

This role implements enterprise-grade Jenkins systemd-to-Docker migration through 5 streamlined phases executed by `migrate.yml` playbook.

## How It Works

### Playbook Entry Point
- **migrate.yml** calls this role, which executes tasks from `tasks/main.yml`
- **rollback.yml** calls `tasks/rollback.yml` to restore systemd service

### Migration Flow (tasks/main.yml)

1. **Phase 1: Discovery & Backup** → Locates Jenkins installation and backs up systemd configuration
2. **Phase 2: API Extract** → Calls Jenkins `/configuration-as-code/export` API to extract JCasC configuration
3. **Phase 3: Docker Setup & Validate** → Installs Docker, generates compose files, validates configurations
4. **Phase 4: Migration** → Stops systemd service, starts Docker containers
5. **Phase 5: Health Check** → Verifies container health and Jenkins API accessibility

### Template Files Generated

- **templates/.env.j2** → Environment variables for Docker Compose (JVM settings, ports, volumes)
- **templates/docker-compose.yml.j2** → Production Docker Compose with Jenkins + healthcheck configuration

### Task File Details

- **tasks/jcasc-reload.yml** → Reloads JCasC configuration via API call or Docker exec fallback after migration
- **tasks/validate.yml** → API connectivity test and configuration file validation
- **handlers/main.yml** → Restart and reload handlers for systemd and Docker services

### Configuration Files

- **defaults/main.yml** → Default variables (Docker image, ports, directories, JVM settings)
- **vars/main.yml** → Internal role variables and computed values
- **meta/main.yml** → Role dependencies and Galaxy metadata
- **meta/argument_specs.yml** → Ansible argument validation specifications

### Key Technical Features

- **API-driven extraction**: Uses Jenkins REST API instead of file parsing for configuration discovery
- **Pure Ansible implementation**: All validation uses native Ansible modules (`community.docker`, `ansible.builtin`)
- **Idempotent operations**: Docker operations use proper state management with `community.docker.docker_compose`
- **Container-aware healthchecks**: Uses `community.docker.docker_container_info` for health validation
- **Volume preservation**: JENKINS_HOME mounted read-write, preserving existing data while allowing normal Jenkins operation