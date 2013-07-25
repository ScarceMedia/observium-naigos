require 'yaml'
require 'mysql'
require 'tempfile'
require 'fileutils'
require 'resolv'
require 'uri'
require 'digest/md5'
require 'syslog'

settings_path = File.join(File.dirname(__FILE__), 'settingsa.yaml')

unless File.exists?(settings_path)
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
          'ios' => {
              'cisco-ios-check-mem' => {
                'community' => true
              },
              'cisco-ios-check-load' => {
                'community' => true
              }
          }
      }
  }
  raise ArgumentError, "#{settings_path} could not be found. Example contents:\n#{example.to_yaml}"
end

settings = YAML.load_file(settings_path)

missing_settings = []

%w(host username password port database weburl nagios_confd nagios_path nagios_initd nagios_host_template nagios_user).each do |required_setting|
  missing_settings << required_setting unless settings.has_key?(required_setting)
end

raise ArgumentError, "Required settings are missing. Please check settings.yaml. \n #{missing_settings.join(', ')}" unless missing_settings.length == 0

Syslog.open('observium-nagios', Syslog::LOG_PID | Syslog::LOG_PERROR, Syslog::LOG_DAEMON | Syslog::LOG_LOCAL3)

Syslog.log Syslog::LOG_INFO, "Connecting to #{settings['database']} on #{settings['host']}"

mysql_client = Mysql.connect(settings['host'], settings['username'], settings['password'], settings['database'], Integer(settings['port']))
Syslog.log Syslog::LOG_INFO, "Connected to #{settings['host']}"

CONFIG_FILE_NAME='observium_nagios_host_services.cfg'

target_config_path = File.join(settings['nagios_confd'], CONFIG_FILE_NAME)

temp_config = Tempfile.new(CONFIG_FILE_NAME)
Syslog.log Syslog::LOG_INFO, "Generating config to temp location #{temp_config.path}"

dns_resolver = Resolv::DNS.new

hosts = {}

mysql_client.query('select device_id, community, lower(hostname), lower(os) from devices').each do |device_id, community, hostname, os|

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

        os_specific_checks.each do |os_specific_check, settings|

          nagios_command = os_specific_check

          nagios_command += "!#{community}" if settings['community'] == true

          service = {
              'use'       => os_specific_check,
              'check_command'   => nagios_command,
              'notes_url' => device_url
          }
          hosts[hostname]['services'] << service
        end
      end
    end
  rescue Exception => ex
    Syslog.log(Syslog::LOG_ERROR, ex.message)
  end
end

if settings['nagios_host_dependency']
  Syslog.log(Syslog::LOG_INFO, 'Querying for dependencies')

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
      Syslog.log(Syslog::LOG_DEBUG, "Skipping #{hostname} because we don't have a host entry in nagios for hostname")
      next
    end

    unless hosts.has_key?(remote_hostname)
      Syslog.log(Syslog::LOG_DEBUG, "Skipping #{remote_hostname} because we don't have a host entry in nagios for remote_hostname")
      next
    end

    Syslog.log(Syslog::LOG_INFO, "Found dependency. #{hostname} on #{remote_hostname}")

    hosts[hostname]['host_dependencies'] << remote_hostname

  end
end

skip_keys ={'services' => true,  'host_dependencies' => true}

File.open(temp_config.path, 'w') do |f|
  f << "# This config is dynamically generated. Do not edit. Your changes will be lost. \n"
  f << "# This config is generate by #{__FILE__}\n"

  #http://observium-web-01.costcoea.lab/device/device=8/
  hosts.sort.each do |hostname, host_values|
    f << "define host {\n"
    f << "  host_name #{hostname}\n"
    host_values.sort.each do |key, value|
      f << "  #{key} #{value}\n" unless skip_keys.has_key?(key)
    end
    f << "}\n\n"

    host_values['services'].each do |service|
      f << "define service {\n"
      f << "  host_name #{hostname}\n"
      service.sort.each do |key, value|
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
else

end

new_config_hash = Digest::MD5.file(temp_config.path)

unless existing_file_hash.nil?
  if new_config_hash == existing_file_hash
    Syslog.log(Syslog::LOG_INFO, 'Config has not changed so exiting')

    exit 0
  end
end

Syslog.log(Syslog::LOG_INFO, "Updating #{target_config_path} (#{existing_file_hash}) with (#{new_config_hash})")

FileUtils.move temp_config.path, target_config_path
FileUtils.chown settings['nagios_user'], settings['nagios_user'], target_config_path

Syslog.log(Syslog::LOG_INFO, "restarting with #{settings['nagios_initd']}")

restart_results = %x(#{settings['nagios_initd']} restart)
puts restart_results
exit