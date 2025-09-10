"""
Jenkins plugin analysis module.
Analyzes Jenkins plugin usage to identify unused plugins for migration.
"""
import sys
import os
import json
import argparse
import time
import urllib.request
import xml.etree.ElementTree as ET
from collections import deque
from multiprocessing import Pool, cpu_count

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
    """Parse an XML file to find plugin attributes and their locations."""
    used_plugins = {}
    try:
        tree = ET.parse(file_path)
        root = tree.getroot()
        for elem in root.findall(".//*[@plugin]"):
            plugin_attr = elem.get('plugin')
            if plugin_attr:
                plugin_id = plugin_attr.split('@')[0]
                used_plugins[plugin_id] = file_path
    except ET.ParseError as e:
        print(f"Warning: Cannot parse XML {file_path}: {e}", file=sys.stderr)
        # Continue processing other files instead of silent failure
    return used_plugins

def process_config_file(file_path):
    """Process a single config file and return its plugins."""
    plugins_in_file = find_used_plugins_in_xml(file_path)
    return file_path, plugins_in_file

def resolve_dependencies(initial_plugins_reasons, all_plugins_info):
    """Resolve all dependencies, tracking the reason for inclusion."""
    resolved_reasons = dict(initial_plugins_reasons)
    queue = deque(list(initial_plugins_reasons.keys()))

    while queue:
        plugin_id = queue.popleft()
        plugin_info = all_plugins_info.get(plugin_id)

        if plugin_info and 'dependencies' in plugin_info:
            for dep in plugin_info['dependencies']:
                dep_id = dep['shortName']
                if dep_id not in resolved_reasons:
                    resolved_reasons[dep_id] = f"Dependency of '{plugin_id}'"
                    queue.append(dep_id)
    return resolved_reasons

def main():
    """Main function to analyze Jenkins plugins and identify unused ones."""
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
    with open(args.plugins_file, 'r', encoding='utf-8') as f:
        installed_plugins_with_versions = [line.strip() for line in f if line.strip() and not line.startswith('#')]
    installed_plugins = {p.split(':')[0] for p in installed_plugins_with_versions}

    # 2. Fetch plugin dependency info from Jenkins API (with caching)
    all_plugins_info = {}
    if args.jenkins_url and args.jenkins_user and args.jenkins_token:
        # Check for cached plugin data
        cache_dir = os.path.join(os.path.dirname(args.plugins_file), '.migration', 'cache')
        os.makedirs(cache_dir, exist_ok=True)

        cache_file = os.path.join(cache_dir, 'plugin_api_data.json')
        cache_timestamp_file = os.path.join(cache_dir, 'plugin_api_data.timestamp')

        # Check if cache is valid (less than 1 hour old)
        cache_valid = False
        if os.path.exists(cache_file) and os.path.exists(cache_timestamp_file):
            try:
                with open(cache_timestamp_file, 'r', encoding='utf-8') as f:
                    cache_timestamp = int(f.read().strip())
                cache_age = int(time.time()) - cache_timestamp
                if cache_age < 3600:  # 1 hour
                    print(f"Using cached plugin API data ({cache_age}s old)", file=sys.stderr)
                    cache_valid = True
            except (ValueError, IOError):
                pass

        if cache_valid:
            try:
                with open(cache_file, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                if data and 'plugins' in data:
                    for p in data['plugins']:
                        all_plugins_info[p['shortName']] = p
            except (json.JSONDecodeError, IOError):
                print("Cache corrupted, fetching fresh data", file=sys.stderr)
                cache_valid = False

        if not cache_valid:
            api_url = f"{args.jenkins_url.rstrip('/')}/pluginManager/api/json?depth=2"
            data = get_api_data(api_url, args.jenkins_user, args.jenkins_token)
            if data and 'plugins' in data:
                # Cache the successful API response
                try:
                    with open(cache_file, 'w', encoding='utf-8') as f:
                        json.dump(data, f)
                    with open(cache_timestamp_file, 'w', encoding='utf-8') as f:
                        f.write(str(int(time.time())))
                except IOError:
                    pass  # Cache write failure is non-critical

                for p in data['plugins']:
                    all_plugins_info[p['shortName']] = p
    else:
        print("Warning: Jenkins API credentials not provided. Dependency resolution may be incomplete.", file=sys.stderr)

    # 3. Find all directly used plugins from config.xml files
    directly_used_plugins_reasons = {}
    config_files = find_config_files(args.jenkins_home)

    # Process config files in parallel
    max_workers = min(cpu_count(), len(config_files), 8)  # Cap at 8 to avoid I/O overload
    if len(config_files) > 1 and max_workers > 1:
        with Pool(max_workers) as pool:
            results = pool.map(process_config_file, config_files)

        # Collect results
        for _, plugins_in_file in results:
            for plugin_id, path in plugins_in_file.items():
                relative_path = os.path.relpath(path, args.jenkins_home)
                directly_used_plugins_reasons[plugin_id] = (
                    f"Directly used in '{relative_path}'")
    else:
        # Fallback to sequential processing for small sets
        for conf_file in config_files:
            plugins_in_file = find_used_plugins_in_xml(conf_file)
            for plugin_id, path in plugins_in_file.items():
                relative_path = os.path.relpath(path, args.jenkins_home)
                directly_used_plugins_reasons[plugin_id] = (
                    f"Directly used in '{relative_path}'")

    # 4. Add all bundled plugins to the used set as a safeguard
    for plugin_id, info in all_plugins_info.items():
        if info.get('bundled', False) and plugin_id not in directly_used_plugins_reasons:
            directly_used_plugins_reasons[plugin_id] = "Bundled core plugin"

    # 5. Resolve all dependencies
    active_plugins_reasons = resolve_dependencies(directly_used_plugins_reasons,
                                                   all_plugins_info)
    active_plugin_ids = set(active_plugins_reasons.keys())

    # 6. Determine unused plugins
    unused_plugins = installed_plugins - active_plugin_ids

    # 7. Generate cleaned plugins list and report
    plugin_version_map = {p.split(':')[0]: p for p in installed_plugins_with_versions}

    with open(args.output_file, 'w', encoding='utf-8') as f:
        f.write("# Jenkins Plugin Analysis Report\n")
        f.write("# Unused plugins have been removed. Kept plugins include a comment explaining why.\n\n")

        sorted_active_plugins = sorted(list(active_plugin_ids))

        for plugin_id in sorted_active_plugins:
            reason = active_plugins_reasons.get(plugin_id, "Unknown reason")
            plugin_with_version = plugin_version_map.get(plugin_id,
                                                         f"{plugin_id}:latest")

            f.write(f"# Kept because: {reason}\n")
            f.write(f"{plugin_with_version}\n\n")

    with open(args.report_file, 'w', encoding='utf-8') as f:
        if unused_plugins:
            f.write("# The following plugins were identified as unused and have been removed:\n")
            for plugin in sorted(list(unused_plugins)):
                f.write(f"{plugin}\n")
        else:
            f.write("# No unused plugins were found.\n")

    print(f"Plugin analysis complete: {len(active_plugin_ids)} active, "
          f"{len(unused_plugins)} unused plugins found.", file=sys.stdout)
    sys.exit(0)

if __name__ == "__main__":
    main()
