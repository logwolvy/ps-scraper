require 'mechanize'
require 'json'
require 'ostruct'
require 'fileutils'

class PluralSightScraper
  attr_reader :username, :password, :opts, :course_info, :courses
  SITEMAP_URL = 'https://www.pluralsight.com/sitemap.xml'
  LOGFILE = 'course_downloads.json'
  MODULES_INFO_URL = "https://app.pluralsight.com/learner/content/courses/:course_name"
  CDN_LINKS_QUERY = %q({"query":"\n        query viewClip {\n          viewClip(input: {\n            author: \"author_name\", \n            clipIndex: clip_index, \n            courseName: \"course_name\", \n            includeCaptions: false, \n            locale: \"en\", \n            mediaType: \"mp4\", \n            moduleName: \"module_name\", \n            quality: \"1280x720\"\n          }) {\n            urls {\n              url\n              cdn\n              rank\n              source\n            },\n            status\n          }\n        }\n      ","variables":{}})
  DEFAULT_OPTS = {
    delay_between_downloads: 10,
    delay_between_courses: 10
  }
  # Add more if you want courses from other domains, see https://app.pluralsight.com/library/browse
  COURSE_DOMAINS = ['software-development', 'it-ops', 'data-professional', 'security-professional']

  def initialize(username, password, opts = {})
    @username = username
    @password = password
    @opts = OpenStruct.new(DEFAULT_OPTS.merge(opts))
  end

  def execute
    parse_sitemap
    set_login_session
    sleep 2
    process_pending_courses
  rescue StandardError, Interrupt => e
    save_progress
    puts "Error Desc: #{e}"
  end

  private

  def parse_sitemap
    if File.exist?(LOGFILE)
      @courses = JSON.parse(File.read(LOGFILE))
    else
      course_list = Nokogiri::XML(
        client.get(SITEMAP_URL).body
      ).remove_namespaces!.xpath("//loc[contains(text(), '/courses/')]").map(&:text)
      @courses = {"done" => [], "pending" => course_list}
    end
  end

  def set_login_session
    client.get('https://app.pluralsight.com/id?redirectTo=%2Fid%2Fdashboard') do |page|
      page.form_with(:action => '/id/') do |f|
        f.Username  = username
        f.Password  = password
      end.click_button
    end
  end

  def process_pending_courses
    courses.fetch("pending").delete_if do |c|
      course_modules_info(c)
      download_course_modules
      courses.fetch("done") << c
      sleep opts.delay_between_courses
      true
    end
  end

  def course_modules_info(course)
    url = MODULES_INFO_URL.dup
    url.gsub!(/(:course_name)/, ':course_name' => course_name(course))
    @course_info = JSON.parse(client.get(url).body)
  end

  def download_course_modules
    unless (course_info.fetch('audiences') & COURSE_DOMAINS).empty?
      author = course_info.dig('modules', 0, 'id').split('|')[1]
      course = course_info.fetch('id')
      puts "Downloading " + course + " by " + author

      course_info.fetch('modules').each do |mod|
        mod_name = mod.fetch('id').split('|').last

        mod.fetch('clips').each_with_index do |clip, i|
          query = CDN_LINKS_QUERY.dup
          query.gsub!(
            /(author_name)|(course_name)|(module_name)|(clip_index)/,
            'author_name' => author,
            'course_name' => course,
            'module_name' => mod_name,
            'clip_index' => i
          )
          res = JSON.parse(post_query(query).body).dig('data', 'viewClip', 'urls')
          download_clip(res, {course: course, mod_name: "#{mod_name}", clip: "#{i} #{clip.fetch('title')}"})

          sleep opts.delay_between_downloads
        end
      end
    end
  end

  def client(new_session = false)
    @client = nil if new_session
    @client ||= Mechanize.new {|agent| agent.user_agent_alias = 'Mac Firefox'}
  end

  def post_query(query)
    client.post 'https://app.pluralsight.com/player/api/graphql', query, {'Content-Type' => 'application/json'}
  rescue StandardError => e
    c += 1
    if c < 5
      sleep 4
      retry unless c < 5
    else
      puts "Error from post_query: #{e}"
    end
  end

  def save_progress
    File.open(LOGFILE, 'w+') do |f|
      f << courses.to_json
    end
  end

  def course_name(course_url)
    course_url.split('/').last
  end

  def download_clip(urls, meta_data)
    path = "Downloads/#{meta_data[:course]}/#{meta_data[:mod_name]}"
    FileUtils.makedirs(path)
    fname = path + "/#{meta_data[:clip]}.mp4"
    system "wget -c -O '#{fname}' #{urls.sample.fetch('url')}"
    puts "Downloaded " + meta_data[:clip]
  rescue StandardError => e
    c += 1
    if c < 5
      sleep 4
      retry unless c < 5
    else
      puts "Error from download_clip: #{e}"
    end
  end
end

# Substitute your account username and password here
PluralSightScraper.new("your_trial_username", "password").execute
