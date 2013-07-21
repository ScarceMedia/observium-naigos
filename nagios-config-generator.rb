require 'yaml'
require 'mysql'
require 'tempfile'
require 'fileutils'
require 'resolv'
require 'uri'
require 'digest/md5'

def log(level, message)
  puts "#{Time.now} #{level} - #{message}"
end

unless File.exists?('settings.yaml')
  example = {
      'host'                 => 'observium-sql.example.com',
      'username'             => 'nagios',
      'password'             => 'supersecret',
      'port'                 => 3306,
      'database'             => 'observium',
      'weburl'               => 'https://observium-web.example.com',
      'nagios_confd'         => '/etc/nagios/conf.d',
      'nagios_path'          => '/usr/sbin/nagios',
      'nagios_initd'         => '/etc/init.d/nagios',
      'nagios_host_template' => 'observium-host',
      'nagios_host_dependency' => true,
      'nagios_os_specific_checks' => {
          'ios' => [
              'observium-ios-check-cpu',
              'observium-ios-check-mem'
          ]
      }
  }
  raise ArgumentError, "settings.yaml could not be found. Example contents:\n#{example.to_yaml}"
end

settings = YAML.load_file('settings.yaml')

missing_settings = []

%w(host username password port database weburl nagios_confd nagios_path nagios_initd nagios_host_template nagios_user).each do |required_setting|
  missing_settings << required_setting unless settings.has_key?(required_setting)
end

raise ArgumentError, "Required settings are missing. Please check settings.yaml. \n #{missing_settings.join(', ')}" unless missing_settings.length == 0

log 'INFO', "Connecting to #{settings['database']} on #{settings['host']}"

mysql_client = Mysql.connect(settings['host'], settings['username'], settings['password'], settings['database'], Integer(settings['port']))
log 'INFO', "Connected to #{settings['host']}"

CONFIG_FILE_NAME='observium_nagios_host_services.cfg'

target_config_path = File.join(settings['nagios_confd'], CONFIG_FILE_NAME)

temp_config = Tempfile.new(CONFIG_FILE_NAME)
log 'INFO', "Generating config to temp location #{temp_config.path}"

dns_resolver = Resolv::DNS.new

hosts = {}

mysql_client.query('select device_id, lower(hostname), lower(os) from devices').each do |device_id, hostname, os|

  device_url = URI.join(settings['weburl'], "device/device=#{device_id}/").to_s

  begin
    address = dns_resolver.getaddress(hostname)

    hosts[hostname] = {
      'address' => address.to_s,
      'use'          => settings['nagios_host_template'],
      'notes_url'    => device_url,
      'services'     => [],
      'host_dependencies' => []
    }

    if settings.has_key?('nagios_os_specific_checks')
      if settings['nagios_os_specific_checks'].has_key?(os)
        os_specific_checks = settings['nagios_os_specific_checks'][os]

        os_specific_checks.each do |os_specific_check|
          service = {
              'use'       => os_specific_check,
              'notes_url' => device_url
          }
          hosts[hostname]['services'] << service
        end
      end
    end
  rescue Exception => ex
    log('ERROR', ex.message)
  end
end

if settings['nagios_host_dependency']
  log('INFO', 'Querying for dependencies')

  mysql_client.query("SELECT
	lower(d.hostname),
	lower(l.remote_hostname)
FROM
	devices d
INNER JOIN
	ports p
ON p.device_id = d.device_id
INNER JOIN
    links l
on p.port_id = l.`local_port_id`
where
	not p.ifAlias is null and
	p.ifAlias <> ''	and
	d.hostname <> l.remote_hostname").each do |hostname, remote_hostname|


    unless hosts.has_key?(hostname)
      log('DEBUG', "Skipping #{hostname} because we don't have a host entry in nagios for hostname")
      next
    end

    unless hosts.has_key?(remote_hostname)
      log('DEBUG', "Skipping #{remote_hostname} because we don't have a host entry in nagios for remote_hostname")
      next
    end

    log('INFO', "Found dependency. #{hostname} on #{remote_hostname}")

    hosts[hostname]['host_dependencies'] << remote_hostname

  end
end

skip_keys ={'services' => true,  'host_dependencies' => true}

File.open(temp_config.path, 'w') do |f|
  f << "# This config is dynamically generated. Do not edit. Your changes will be lost. \n"
  f << "# This config is generate by #{__FILE__}\n"

  #http://observium-web-01.costcoea.lab/device/device=8/
  hosts.each do |hostname, host_values|
    f << "define host {\n"
    f << "  host_name #{hostname}\n"
    host_values.each do |key, value|
      f << "  #{key} #{value}\n" unless skip_keys.has_key?(key)
    end
    f << "}\n\n"

    host_values['services'].each do |service|
      f << "define service {\n"
      f << "  host_name #{hostname}\n"
      service.each do |key, value|
        f << "  #{key} #{value}\n" unless skip_keys.has_key?(key)
      end
      f << "}\n\n"
    end

    if settings['nagios_host_dependency']
      host_values['host_dependencies'].each do |dependant_hostname|
        f << "define hostdependency {\n"
        f << "  host_name #{hostname}\n"
        f << "  dependent_host_name #{dependant_hostname}\n"
        f << "  inherits_parent 0\n"
        f << "  notification_failure_criteria d,u\n"
        f << "}\n"
      end
    end
  end
end

existing_file_hash = nil

if File.exists?(target_config_path)
  existing_file_hash = Digest::MD5.file(target_config_path)
end

new_config_hash = Digest::MD5.file(temp_config.path)

unless existing_file_hash.nil?
  if new_config_hash == existing_file_hash
    log('INFO', 'Config has not changed so exiting')

    exit 0
  end
end

FileUtils.move temp_config.path, target_config_path
FileUtils.chown settings['nagios_user'], settings['nagios_user'], target_config_path

restart_results = %x(#{settings['nagios_initd']} restart)
puts restart_results
exit