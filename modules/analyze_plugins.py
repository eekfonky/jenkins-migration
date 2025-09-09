import sys
import os
import json
import argparse
import urllib.request
import xml.etree.ElementTree as ET
from collections import deque

def get_api_data(url, user, token):
    """Fetch data from Jenkins API."""
    try:
        req = urllib.request.Request(url)
        if user and token:
            auth_string = f"{user}:{token}".encode('utf-8')
            auth_header = b'Basic ' + urllib.request.HTTPPasswordMgrWithDefaultRealm().find_user_password(None, url, auth_string)[0]
            req.add_header("Authorization", auth_header)

        with urllib.request.urlopen(req, timeout=30) as response:
            if response.status == 200:
                return json.loads(response.read().decode('utf-8'))
        return None
    except Exception as e:
        print(f"Error fetching API data from {url}: {e}", file=sys.stderr)
        return None

def find_config_files(jenkins_home):
    """Find all config.xml files in Jenkins home."""
    config_files = []
    # Add top-level config files
    for root_file in os.listdir(jenkins_home):
        if root_file.endswith('.xml'):
            config_files.append(os.path.join(jenkins_home, root_file))

    # Add config files from jobs, nodes, users, views, etc.
    for root, _, files in os.walk(jenkins_home):
        for name in files:
            if name == 'config.xml':
                config_files.append(os.path.join(root, name))
    return config_files

def find_used_plugins_in_xml(file_path):
    """Parse an XML file to find plugin attributes."""
    used_plugins = set()
    try:
        tree = ET.parse(file_path)
        root = tree.getroot()
        # Find all tags with a 'plugin' attribute
        for elem in root.findall(".//*[@plugin]"):
            plugin_attr = elem.get('plugin')
            if plugin_attr:
                # Format is often "plugin-id@version"
                used_plugins.add(plugin_attr.split('@')[0])
    except ET.ParseError:
        # Ignore malformed XML files
        pass
    return used_plugins

def resolve_dependencies(initial_plugins, all_plugins_info):
    """Resolve all dependencies for a given set of plugins."""
    resolved = set(initial_plugins)
    queue = deque(list(initial_plugins))

    while queue:
        plugin_id = queue.popleft()
        plugin_info = all_plugins_info.get(plugin_id)

        if plugin_info and 'dependencies' in plugin_info:
            for dep in plugin_info['dependencies']:
                dep_id = dep['shortName']
                if dep_id not in resolved:
                    resolved.add(dep_id)
                    queue.append(dep_id)
    return resolved

def main():
    parser = argparse.ArgumentParser(description="Analyze Jenkins plugins to find unused ones.")
    parser.add_argument("--jenkins-home", required=True, help="Path to JENKINS_HOME.")
    parser.add_argument("--plugins-file", required=True, help="Path to plugins.txt.")
    parser.add_argument("--output-file", required=True, help="Path to write the cleaned plugins.txt.")
    parser.add_argument("--report-file", required=True, help="Path to write the report of unused plugins.")
    parser.add_argument("--jenkins-url", help="Jenkins URL for API access.")
    parser.add_argument("--jenkins-user", help="Jenkins user for API access.")
    parser.add_argument("--jenkins-token", help="Jenkins API token.")
    args = parser.parse_args()

    # 1. Read the list of currently installed plugins
    with open(args.plugins_file, 'r') as f:
        installed_plugins_with_versions = [line.strip() for line in f if line.strip() and not line.startswith('#')]
    installed_plugins = {p.split(':')[0] for p in installed_plugins_with_versions}

    # 2. Fetch plugin dependency info from Jenkins API
    all_plugins_info = {}
    if args.jenkins_url and args.jenkins_user and args.jenkins_token:
        api_url = f"{args.jenkins_url.rstrip('/')}/pluginManager/api/json?depth=2"
        data = get_api_data(api_url, args.jenkins_user, args.jenkins_token)
        if data and 'plugins' in data:
            for p in data['plugins']:
                all_plugins_info[p['shortName']] = p
    else:
        print("Warning: Jenkins API credentials not provided. Dependency resolution may be incomplete.", file=sys.stderr)

    # 3. Find all directly used plugins from config.xml files
    directly_used_plugins = set()
    config_files = find_config_files(args.jenkins_home)
    for conf_file in config_files:
        directly_used_plugins.update(find_used_plugins_in_xml(conf_file))

    # 4. Add all bundled plugins to the used set as a safeguard
    for plugin_id, info in all_plugins_info.items():
        if info.get('bundled', False):
            directly_used_plugins.add(plugin_id)

    # 5. Resolve all dependencies
    active_plugins = resolve_dependencies(directly_used_plugins, all_plugins_info)

    # 6. Determine unused plugins
    unused_plugins = installed_plugins - active_plugins

    # 7. Generate cleaned plugins list and report
    cleaned_plugins_list = [p for p in installed_plugins_with_versions if p.split(':')[0] in active_plugins]

    with open(args.output_file, 'w') as f:
        f.write("# Cleaned Jenkins plugins list\n")
        f.write("# Unused plugins have been removed based on configuration analysis.\n\n")
        for plugin in sorted(cleaned_plugins_list):
            f.write(f"{plugin}\n")

    with open(args.report_file, 'w') as f:
        if unused_plugins:
            f.write("# The following plugins were identified as unused and have been removed:\n")
            for plugin in sorted(list(unused_plugins)):
                f.write(f"{plugin}\n")
        else:
            f.write("# No unused plugins were found.\n")

    print(f"Analysis complete. Found {len(unused_plugins)} unused plugins.", file=sys.stdout)
    sys.exit(0)

if __name__ == "__main__":
    main()
