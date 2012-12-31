require 'rexml/document'

$: << ENV['TM_SUPPORT_PATH'] + '/lib'
require "textmate"
require 'cgi'

class RtfExporter
  
  def initialize
    @styles={}  
    @colors = ""
    @num_colors=1
  end
  
  def generate_rtf input
    generate_stylesheet_from_theme
    doc = rtf_document input
    CGI::unescapeHTML(doc)
  end
  
  def add_style_recursive scopes, style, styles
    current = scopes.shift.strip
    styles[current] ||= {}
    if scopes.empty?
      styles[current][:default] = style
    else
      add_style_recursive scopes, style, styles[current]
    end
  end
  
  def add_style_from_textmate_theme name, settings
    style = {}
    style_names = name.split ','
    style_names.each do |sn|
      add_style_recursive sn.split('.'), style, @styles
    end
        
    if fs = settings['fontStyle']
      style[:bold] = fs =~ /bold/
      style[:italic] if fs =~ /italic/
      style[:underline] if fs =~ /underline/
    end
    if col = settings['foreground']
      style[:color] = hex_color_to_rtf col
      @colors << style[:color]
      style[:color_index] = @num_colors+=1
    end
  end
  
  def hex_color_to_rtf hex
    hex =~ /#(..)(..)(..)/
    r = $1.hex
    g = $2.hex
    b = $3.hex
    return "\\red#{r}\\green#{g}\\blue#{b};"
  end
  
  def generate_stylesheet_from_theme(theme_class = nil)
    theme_class = '' if theme_class == nil
    require "#{ENV['TM_SUPPORT_PATH']}/lib/osx/plist"

    # Load TM preferences to discover the current theme and font settings
    
    textmate_pref_files = [File.expand_path('~/Library/Preferences/com.macromates.textmate.plist'), File.expand_path('~/Library/Preferences/com.macromates.TextMate.preview.plist')]
    textmate_pref_files_opened = nil
    textmate_pref_files.each do |filePath|
      break if File.file?(filePath) && textmate_pref_files_opened = File.open(filePath)
    end
    unless textmate_pref_files_opened
      print "Preference file not found!"
      abort
    end
    
    prefs = OSX::PropertyList.load(textmate_pref_files_opened)
    
    # theme_uuid = prefs['themeUUID'] || prefs['OakThemeManagerSelectedTheme']
    theme_uuid = "71D40D9D-AE48-11D9-920A-000D93589AF6"

    # Load the active theme. Unfortunately, this requires us to scan through
    # all discoverable theme files...
    unless theme_plist = load_theme_with_path(ENV['TM_CURRENT_THEME_PATH'])
      print "Could not locate your theme file or it may be corrupt or unparsable!"
      abort
    end

    theme_comment = theme_plist['comment']
    theme_name = theme_plist['name']
    theme_class.replace(theme_name)
    theme_class.downcase!
    theme_class.gsub!(/[^a-z0-9_-]/, '_')
    theme_class.gsub!(/_+/, '_')

    @font_name = prefs['OakTextViewNormalFontName'] || 'Monaco'
    @font_size = (prefs['OakTextViewNormalFontSize'] || 11).to_s
    @font_size.sub! /\.\d+$/, ''
    @font_size = @font_size.to_i * 3
    
    @font_name = '"' + @font_name + '"' if @font_name.include?(' ') &&
      !@font_name.include?('"')
      

    theme_plist['settings'].each do | setting |
      if (!setting['name'] and setting['settings'])
        body_bg = setting['settings']['background'] || '#ffffff'
        @body_bg ||= body_bg
        body_fg = setting['settings']['foreground'] || '#000000'
        selection_bg = setting['settings']['selection']
        body_bg = hex_color_to_rtf(body_bg)
        body_fg = hex_color_to_rtf(body_fg)
        selection_bg = hex_color_to_rtf(selection_bg) if selection_bg
        @colors << body_fg
        next
      end
      if setting['name'] && setting['scope']
        scope_name = setting['scope']
        # scope_name.gsub! /(^|[ ])-[^ ]+/, '' # strip negated scopes
        # scope_name.gsub! /\./, '_' # change inner '.' to '_'
        # #scope_name.gsub! /(^|[ ])/, '\1.'
        # scope_name.gsub! /[ ]/, '_' # spaces to underscores
        # scope_name.gsub! /(^|,\s+)/m, '\1'
        add_style_from_textmate_theme scope_name, setting['settings']
      end
    end
  end

  def color_table
    "{\\colortbl;#{@colors}}"
  end
  
  def font_table
    "{\\fonttbl {\\f0 #{@font_name};}}"
  end
  
  def rtf_document input
    <<-RTF_DOC
{\\rtf
#{font_table}
#{color_table}
{\\pard\\ql
\\f0\\fs#{@font_size} #{document_to_rtf input}
}}
RTF_DOC
  end
  
  # {\\rtf
  # #{font_table}
  # #{color_table}
  # {\\pard\\ql
  # \\f0\\fs#{@font_size}\\cf1\\b Hello, World!\\line
  # \\tab \\cf2 Next Line\\line
  # \\tab\\tab\\i \\cf3 Another line
  # }}
  
  def load_theme_with_path(path)
    OSX::PropertyList.load(File.open(path))
  end
  
  def detab(str, width)
    lines = str.split(/\n/)
    lines.each do | line |
      line_sans_markup = line.gsub(/<[^>]*>/, '').gsub(/&[^;]+;/i, '.')
      while (index = line_sans_markup.index("\t"))
        tab = line_sans_markup[0..index].jlength - 1
        padding = " " * ((tab / width + 1) * width - tab)
        line_sans_markup.sub!("\t", padding)
        line.sub!("\t", padding)
      end
    end
    return lines.join("\n")
  end
  
  def document_to_rtf(input, opt = {})
    # Read the source document / selection
    # Convert tabs to spaces using configured tab width
    input = detab(input, (ENV['TM_TAB_SIZE'] || '2').to_i)

    input.gsub! /\\/, "__backslash__"
    input.gsub! /\\n/, "__newline__"
    input.gsub! /\n/, "\\\\line\n"
    input.gsub! /\{/, "\\{" 
    input.gsub! /\}/, "\\}"
    input.gsub! /__newline__/, "\\\\\\n"
    input.gsub! /__backslash__/, "\\\\\\"

    
    @style_stack = []

    # Meat. The poor-man's tokenizer. Fortunately, our input is simple
    # and easy to parse.
    tokens = input.split(/(<[^>]*>)/)
    code_rtf = ''
    tokens.each do |token|
      case token
      when /^<\//
        # closing tag
        pop_style
      when /^<>$/
        # skip empty tags, resulting from name = ''
      when /^</
        if token =~ /^<([^>]+)>$/
          scope = $1
          push_style scope
        end
      else
        next if token.empty?
        code_rtf << '{'
        style = current_style_as_rtf
        if style && !style.empty? && !token.strip.empty?
          code_rtf << current_style_as_rtf << ' '
        end
        code_rtf << token << '}'
      end
    end
    
    return code_rtf
  end
  
  def current_style
    @style_stack[0] || {}
  end
  
  def get_style_recursive scopes, styles
    #scopes -= ["punctuation", "definition"] # nasty workaround hack

    return nil unless styles
    cur = scopes.shift.strip
    
    style = nil
    unless scopes.empty?
      style = get_style_recursive(scopes, styles[cur]) || style
    end
    style ||= styles[:default]
  end
  
  def current_style_as_rtf
    cur = current_style
    rtf = ''
    rtf << "\\cf#{cur[:color_index]}" if cur[:color_index]
    rtf << "\\b" if cur[:bold]
    rtf << "\\i" if cur[:italic]
    rtf << "\\ul" if cur[:underline]
    rtf
  end
  
  def push_style name
    cur = current_style
    new_style = get_style_recursive(name.split('.'), @styles)
    # p "current: #{cur.inspect}"
    new_style = cur.merge new_style if new_style
    new_style ||= cur || {}
    unless new_style[:color_index]
      #45 works for Sunburst theme; 0 for Eiffle or IDLE theme
      new_style[:color_index] = (@body_bg == '#000000') ? 45 : 0
    end
    @style_stack.unshift new_style
    new_style
  end
  
  def pop_style
    @style_stack.shift
  end
  
end

