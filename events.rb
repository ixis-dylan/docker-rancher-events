require 'docker'
require 'net/http'
require 'uri'
require 'pp'
require 'rest-client'
require 'json'
puts '#########################################################################'
pp Docker.version
pp Docker.info
puts '#########################################################################'

ENV['RANCHER_MANAGER_HOSTNAME'] ||= ENV['CATTLE_URL']
ENV['RANCHER_API_KEY'] ||=  ENV['CATTLE_ACCESS_KEY']
ENV['RANCHER_API_SECRET'] ||= ENV['CATTLE_SECRET_KEY']

raise 'Environmental variable RANCHER_MANAGER_HOSTNAME is required' unless ENV['RANCHER_MANAGER_HOSTNAME']
raise 'Environmental variable RANCHER_LOADBALANCER_PORT is required' unless ENV['RANCHER_LOADBALANCER_PORT']
raise 'Environmental variable RANCHER_API_KEY is required' unless ENV['RANCHER_API_KEY']
raise 'Environmental variable RANCHER_API_SECRET is required' unless ENV['RANCHER_API_SECRET']
raise 'Environmental variable DEPOT_DOMAIN is required' unless ENV['DEPOT_DOMAIN']

def get_default_loadbalancer
  loadbalancer_response_body = RestClient::Request.execute(:method => :get,
                                                      :url => "#{ENV['RANCHER_MANAGER_HOSTNAME']}/loadbalancers",
                                                      :user => ENV['RANCHER_API_KEY'],
                                                      :password => ENV['RANCHER_API_SECRET'],
                                                      :headers => {
                                                          'Accept' => 'application/json',
                                                          'Content-Type' => 'application/json'
                                                      }
  )

  loadbalancer_response = JSON.parse(loadbalancer_response_body)
  default_lb = loadbalancer_response['data'].find {|loadbalancer|
    (loadbalancer['type'] == 'loadBalancer') && (loadbalancer['name'] == 'utility_lb')
  }
  return default_lb
end

def get_service_stack_name(service)
  environment_response_body = RestClient::Request.execute(:method => :get,
                                                           :url => service['links']['environment'],
                                                           :user => ENV['RANCHER_API_KEY'],
                                                           :password => ENV['RANCHER_API_SECRET'],
                                                           :headers => {
                                                               'Accept' => 'application/json',
                                                               'Content-Type' => 'application/json'
                                                           }
  )

  environment_response = JSON.parse(environment_response_body)
  return environment_response['name']
end

def generate_loadbalancer_service_links
  #get the current active services using the metadata service.
  service_response_body = RestClient::Request.execute(:method => :get,
                              :url => "#{ENV['RANCHER_MANAGER_HOSTNAME']}/services",
                              :user => ENV['RANCHER_API_KEY'],
                              :password => ENV['RANCHER_API_SECRET'],
                              :headers => {
                                  'Accept' => 'application/json',
                                  'Content-Type' => 'application/json'
                              }
  )
  service_response = JSON.parse(service_response_body)

  service_links = []
  service_response['data'].each { |service|
    next if service['type'] != 'service'
    link = service['launchConfig'].fetch('labels',{}).fetch('depot.lb.link', 'false')
    if link == 'true'
      port = service['launchConfig'].fetch('labels',{}).fetch('depot.lb.port', '80')
      stack_name = get_service_stack_name(service)
      service_links.push({
       'serviceId' => service['id'],
        'ports' => ["#{stack_name}.#{ENV['DEPOT_DOMAIN']}:#{ENV['RANCHER_LOADBALANCER_PORT']}=#{port}"]
      })
    end
  }
  service_links
end

def set_loadbalancer_service_links(loadbalancer, service_links)
  puts 'requesting the links service url: ' +  loadbalancer['links']['service']
  loadbalancer_service_response_body = RestClient::Request.execute(:method => :get,
                                                          :url => loadbalancer['links']['service'],
                                                          :user => ENV['RANCHER_API_KEY'],
                                                          :password => ENV['RANCHER_API_SECRET'],
                                                          :headers => {
                                                              'Accept' => 'application/json',
                                                              'Content-Type' => 'application/json'
                                                          }
  )

  loadbalancer_service_response = JSON.parse(loadbalancer_service_response_body)

  #now we have to extract the loadbalancer service link post url and post our service links there

  payload = {"serviceLinks" => service_links}.to_json

  puts 'serviceLinks payload: ' + payload
  puts 'posting payload to url: '+ loadbalancer_service_response['actions']['setservicelinks']
  set_service_links_response_body = RestClient::Request.execute(:method => :post,
                                                                   :payload => payload,
                                                                   :url => loadbalancer_service_response['actions']['setservicelinks'],
                                                                   :user => ENV['RANCHER_API_KEY'],
                                                                   :password => ENV['RANCHER_API_SECRET'],
                                                                   :headers => {
                                                                       'Accept' => 'application/json',
                                                                       'Content-Type' => 'application/json'
                                                                   }
  )

  set_service_links_response = JSON.parse(set_service_links_response_body)
  puts 'service_links repsonse:'
  pp  set_service_links_response
  return set_service_links_response

end


# # Shortcut

puts 'Watching for events'
Docker.options[:read_timeout] = 3600 # timeout after an hour, should automatically restart by docker. nil and 0 dont work
Docker::Event.stream {|event|
  if ['start','stop'].include?(event.status)
    #this is a container start/stop event, we need to handle it.
    container = Docker::Container.get(event.id)
    labels = container.info['Config']['Labels'] || {}

    #check if the required labels exist:
    # depot.lb.link
    if labels['depot.lb.link']
      puts "processsing #{event.status} event on service: #{labels['io.rancher.stack_service.name']}"
      puts 'event:'
      pp event
      puts 'containers'
      #pp container

      puts 'generate loadbalancer service links.'
      service_links = generate_loadbalancer_service_links()
      puts 'service_links:'
      pp service_links

      puts 'find the default loadbalancer'
      load_balancer = get_default_loadbalancer()
      puts load_balancer['name']

      puts 'set the loadbalancer service links'
      resp = set_loadbalancer_service_links(load_balancer, service_links)
      puts 'response:'
      pp resp

    end
  end
}


