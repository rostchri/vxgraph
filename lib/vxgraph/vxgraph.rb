require 'graphviz'
require 'yaml'

module VXGraph

  $vxdg = {}
  $vxdmp = {}
  $vxenclosure = {}


  def ssh_execute(hostname,precmds,cmds,direct=false)
    cache_last = []
    begin
      gateway = Net::SSH::Gateway.new('dskinst001', 'root', :verbose => Logger::ERROR)
      gateway.ssh(hostname, "root", {:verbose => Logger::ERROR} ) do |ssh|

        precmds.each_with_index do |command,index|
          yield index, ssh.exec!(command)
        end

        cmds.each do |command|
          ssh.open_channel do |channel|

            # stderr
            channel.on_extended_data do |channel,type,data|
              data.each_line { |l| printf("### STD-ERROR @%d [CMD: %s]  %s\n", channel.local_id + precmds.size , command , l.chop) } if type==1 
            end

            # stdout
            channel.on_data do |channel,data|
              if data[-1] == "\n"
                if cache_last[channel.local_id]
                  if direct==false
                    cache_last[channel.local_id]+=data
                  else
                    yield channel.local_id, cache_last[channel.local_id] + data
                    cache_last[channel.local_id] = nil
                  end 
                else
                  if direct==false
                    cache_last[channel.local_id] = data
                  else
                    yield channel.local_id, data
                  end 
                end
              else
                # Falls hinten kein \n so ist die Zeile nicht komplett übermittelt und muss als Präfix für die nächste Zeile gecached werden    
                cache_last[channel.local_id] ? cache_last[channel.local_id] += data : cache_last[channel.local_id] = data
              end
            end

            # eof
            channel.on_eof do |channel|
              #printf("### EOF-CHAN: %d CMD: %s\n", channel.local_id, command)
              yield channel.local_id, cache_last[channel.local_id] if direct==false
            end

            channel.exec command
          end
        end
      end
      gateway.shutdown!
    rescue Net::SSH::HostKeyMismatch => e
      puts "remembering new key: #{e.fingerprint}"
      e.remember_host!
      retry
    rescue Exception => ex
      printf("### ERROR: %s [%s]\n%s\n",ex.message, ex.class, ex.backtrace.join("\n"))
    end
  end

  def parse_vxdisk(info)
    linenumber = 0
    dmpdev  = nil
    #File.open("import/#{$hostname}/vxdisk.txt")
    info.each_line  do |line| 
      line.chomp!
      linenumber+=1
      begin
        if line =~ /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+).*$/
          dmpdev = $1
          diskgroup = $4
          unless $vxdmp[dmpdev].nil?
	          if diskgroup =~ /\((.*)\)/
              $vxdmp[dmpdev][:dg] = $1
            elsif diskgroup != "-"
              $vxdmp[dmpdev][:dg] = $diskgroup
            end
          end
        else
          printf("### PARSING-ERROR for line: %s\n",line)
        end
      rescue Exception => ex
        printf "### ERROR %s %s\n", ex.message, ex.backtrace.join("\n")
        exit 1
      end
    end
  end

  def parse_vxdmpadm_paths(info)
    linenumber = 0
    dmpdev  = nil
    #File.open("import/#{$hostname}/vxdmpadm-paths.txt")
    info.each_line do |line| 
      line.chomp!
      linenumber+=1
      begin
        if line[0] != "#" && line =~ /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+).*$/
          dmpdev = $4 
          if dmpdev != "DMPNODENAME" && ($vxdmp[dmpdev].nil? || $vxdmp[dmpdev][:path][$1].nil?)
             $vxdmp[dmpdev] = {:dmpdev => dmpdev, :path => {}} if $vxdmp[dmpdev].nil?
             $vxdmp[dmpdev][:enclosure] = $5
             $vxdmp[dmpdev][:path][$1] = {:state => $2, :type => $3, :ctrl => $6, :attr => $7}
             printf "### WARNING Following path to dmpdev %s is %s: %s \n", dmpdev, $2, $1 if $2 != "ENABLED(A)"
          end
        end
      rescue Exception => ex
        printf "### ERROR %s %s\n", ex.message, ex.backtrace.join("\n")
        exit 1
      end
    end
  end

  def parse_vxdmpadm_dmpnodes(info)
    linenumber = 0
    dmpdev  = nil
    #File.open("import/#{$hostname}/vxdmpadm-dmpnodes.txt")
    info.each_line  do |line| 
      line.chomp!
      linenumber+=1
      begin
        if line =~ /^(\S+)\s+=\s+(.*)$/
          dmpdev = $2  if $1 == "dmpdev"
          printf "### WARNING Following dmpdev is %p: %p\n", $2, $vxdmp[dmpdev] if $1 == "state" && $2 != "enabled"
          unless dmpdev.nil? || ["###path"].include?($1)
            if $1 == "path"
              pathinfo = $2
              if pathinfo =~ /(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)$/
                $vxdmp[dmpdev][:path]={} if $vxdmp[dmpdev][:path].nil?
                $vxdmp[dmpdev][:path][$1] = {:state => $2, :type => $3, :transport => $4, :ctrl => $5, :hwpath => $6, :aportID=> $7, :aportWWN => $8, :attr => $9 }
                # printf("%p\n",$vxdmp[dmpdev][:path][$1])
              else
		            puts "### ERROR reading path-info: #{pathinfo}"
              end
            else
             $vxenclosure[$2] = {:name => $2} if $1 == "enclosure" && $vxenclosure[$2].nil?
	           $vxdmp[dmpdev]={} if $vxdmp[dmpdev].nil?
             $vxdmp[dmpdev][$1.to_sym] = $2
            end
          end
        end
      rescue Exception => ex
        printf "### ERROR %s %s\n", ex.message, ex.backtrace.join("\n")
        #printf "### CONTEXT: dg=%s vol=%s plex=%s\n", dgname, volname, plexname
        #printf "### FOR LINENUMBER: %d) %p\n", linenumber, line
        exit 1
      end
    end
  end

  def vxsize(size) 
    sprintf("%2.2f GB", size.to_i * 512 / (1024*1024*1000))
  end

  def parse_vxprint(info)
    dgname  = nil
    volname = nil
    plexname = nil
    subvolumename = nil
    linenumber = 0
    #File.open("import/#{$hostname}/vxprint.txt")
    info.each_line  do |line| 
     line.chomp!
     linenumber+=1
     begin
        if line =~ /^dg\s+(\S+)\s+(\S+)\s+.*/
           dgname = $1
           $vxdg[dgname] = {:name => dgname, :assoc => $2}
           # printf "### Diskgroup %p\n", $vxdg[dgname]
        end

        if line =~ /^dm\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)/
           $vxdg[dgname][:dm] = {} if $vxdg[dgname][:dm].nil?
           $vxdg[dgname][:dm][$1] = dm = {:name => $1, :assoc => $2, :size => $4}
           #printf "### Diskmedia %p\n", dm
        end

        if line =~ /^v\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+.*/
           volname = $1
           layered = (volname =~ /.*-L\d*$/ && volname.gsub(/(.*)-L(\d*)$/,"\\1") == subvolumename.gsub(/(.*)-S(\d*)$/,"\\1")) ? true : false
           # puts "### Part of layered volume found: #{volname}" if layered
           $vxdg[dgname][:v] = {} if $vxdg[dgname][:v].nil?
           $vxdg[dgname][:v][volname] = {:name => volname, :type => $2, :state => $3, :size => $4, :condition => $6 , :layered => layered }
           # printf "### Volume %p\n", $vxdg[dgname][:v][volname]
        end

        if line =~ /^pl\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+.*/
           plexname = $1
           plex = {:name => plexname, :assoc => $2, :state => $3, :size => $4, :condition => $6}
           if plex[:state] == "ENABLED"
              $vxdg[dgname][:v][volname][:pl] = {} if $vxdg[dgname][:v][volname][:pl].nil?
              $vxdg[dgname][:v][volname][:pl][plexname] = plex
              # printf "### Plex %p\n", plex
           else
              $vxdg[dgname][:pl] = {} if $vxdg[dgname][:pl].nil?
              $vxdg[dgname][:pl][plexname] = plex
              printf "### WARNING Following Plex is disabled: %p\n", plex
           end
        end

        if line =~ /^sv\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+.*/
          subvolumename = $1
          subvolume = {:name => subvolumename, :assoc => $2, :state => $3, :size => $4, :condition => $6}
          # puts "### Layered volume found: #{subvolumename}"
          unless $vxdg[dgname][:v][volname][:pl][$2].nil?
            $vxdg[dgname][:v][volname][:pl][$2][:sv]=[] if $vxdg[dgname][:v][volname][:pl][$2][:sv].nil?
            $vxdg[dgname][:v][volname][:pl][$2][:sv] << subvolume
          end
        end

        if !plexname.nil? && line =~ /^sd\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+.*/
          sd = {:name => $1, :assoc => $2, :state => $3, :size => $4} 
          if $1 =~ /^(\S+)-(\S+)$/
            sd[:dmpdev]=$1
          end
          if !$vxdg[dgname][:v].nil? && !$vxdg[dgname][:v][volname].nil? && !$vxdg[dgname][:v][volname][:pl].nil? && !$vxdg[dgname][:v][volname][:pl][plexname].nil? && $vxdg[dgname][:v][volname][:pl][plexname][:name] == sd[:assoc]
            $vxdg[dgname][:v][volname][:pl][plexname][:sd] = [] if $vxdg[dgname][:v][volname][:pl][plexname][:sd].nil?
            $vxdg[dgname][:v][volname][:pl][plexname][:sd] << sd
            #printf "### Subdisk %p\n", sd
          else
            # Disabled plexes are not associated to a volume - instead they are associated to a diskgroup - now associate all subdisk too
            unless $vxdg[dgname][:pl].nil? || $vxdg[dgname][:pl][plexname].nil?
              $vxdg[dgname][:pl][plexname][:sd] = [] if $vxdg[dgname][:pl][plexname][:sd].nil?
              $vxdg[dgname][:pl][plexname][:sd] << sd
            else
              # unused subdisks - no association to a volume or a plex
              printf "### WARNING: UNUSED SUBDISK: %p \n", sd
              $vxdg[dgname][:sd] = [] if $vxdg[dgname][:sd].nil?
              $vxdg[dgname][:sd] << sd
            end
          end
        end

     rescue Exception => ex
       printf "### ERROR %s %s\n", ex.message, ex.backtrace.join("\n")
       printf "### CONTEXT: dg=%s vol=%s plex=%s\n", dgname, volname, plexname
       printf "### FOR LINENUMBER: %d) %p\n", linenumber, line
       exit 1
     end
    end
  end
  
  def plot_graphs
    # initialize new Graphviz graph
    GraphViz.digraph( :G ) do |graph|

      graph[:truecolor => true,  :rankdir => "TB" ] # :bgcolor => "transparent", :rankdir => "LR"

      # set global node options
      graph.node[:color]    = "#ddaa66"
      graph.node[:style]    = "filled"
      graph.node[:penwidth] = "1"
      graph.node[:fontname] = "Trebuchet MS"
      graph.node[:fontsize] = "8"
      graph.node[:fillcolor]= "#ffeecc"
      graph.node[:fontcolor]= "#775500"
      graph.node[:margin]   = "0.1"

      # set global edge options
      graph.edge[:color]    = "#999999"
      graph.edge[:weight]   = "1"
      graph.edge[:fontsize] = "6"
      graph.edge[:fontcolor]= "#444444"
      graph.edge[:fontname] = "Verdana"
      graph.edge[:dir]      = "none"
      graph.edge[:penwidth] = "1"
      graph.edge[:arrowsize]= "0.5"
      graph.edge[:labelfloat]= "false"


      enc_graph=graph.subgraph
      dg_graph=graph.subgraph
      sd_graph=graph.subgraph
      dmp_graph=graph.subgraph

      enc_graph[:rank => "same"]
      dg_graph[:rank => "same"]
      dmp_graph[:rank => "same"]
      sd_graph[:rank => "same"]

      $vxenclosure.each do |encname,encdata|
         #encdata[:graphnode] = enc_graph.add_nodes(encname, :shape => "doublecircle", :label => encname)
      end

      $vxdmp.each do |dmpname,dmpdata|
         dmpdata[:graphnode] = dmp_graph.add_nodes("LUN\n#{dmpdata[:state]}\n#{dmpname}\n#{dmpdata[:enclosure]}\n#{dmpdata[:'cab-sno']}", :shape => "polygon") 
         # graph.add_edges(dmpdata[:graphnode],$vxenclosure[dmpdata[:enclosure]][:graphnode]) 

         # markiere alle luns die von der ds8000 aus rz13 kommen
         #if dmpdata[:enclosure] == "DS8RZD1"
         #   dmpdata[:graphnode][:penwidth]= "3" 
         #   dmpdata[:graphnode][:color]   = "#ff0000"
         #end

         if dmpdata[:enclosure] == "DS8RZD1"
           dmpdata[:graphnode][:style]="dashed,rounded"
         else
           dmpdata[:graphnode][:style]="dashed"
         end
      end

      $vxdg.each do |dgname,dgdata|
         #next unless dgname=="orasvc11_dg"
         dgdata[:graphnode] = dg_graph.add_nodes("Diskgroup\n#{dgname}\nImported", :shape => "oval")

         # disabled plexes - no association to volume
         dgdata[:pl].each do |plexname,plexdata|
            plexdata[:graphnode] = graph.add_nodes("Plex\n#{plexname}\n#{vxsize(plexdata[:size])}\n#{plexdata[:condition]}\n#{plexdata[:state]}", :style => "dashed", :shape => "box")
            # Verbindung Diskgroup -> Inaktiver Plex
            edge = graph.add_edges(dgdata[:graphnode], plexdata[:graphnode], :weight => 5)
            edge[:style] = "dashed"

            subdisklabels = plexdata[:sd].inject([]) {|r,sd| r << "<#{sd[:name]}> Subdisk\n#{sd[:name]}\n#{vxsize(sd[:size])}"}
            plexdata[:subdisks_graphnode] = sd_graph.add_nodes("subdisks #{plexname}", "shape" => "record", :style => "dashed", "label" => subdisklabels.join("|") ) unless subdisklabels.empty?

            # Verbindung Plex ->  Subdisk
            edge = graph.add_edges(plexdata[:graphnode],plexdata[:subdisks_graphnode], :tailport => plexname, :weight => 10)
            edge[:style] = "dashed"

            plexdata[:sd].each do |sd|
              if $vxdmp[dgdata[:dm][sd[:dmpdev]][:assoc]]
                 $vxdmp[dgdata[:dm][sd[:dmpdev]][:assoc]][:graphnode][:style]="filled"
                   # Verbindung Subdisk -> dmpdev
                   $vxdmp[dgdata[:dm][sd[:dmpdev]][:assoc]][:path].each do |pathname,path|
                     $vxdmp[dgdata[:dm][sd[:dmpdev]][:assoc]][:associated] = :semi
      	       #if path[:transport] == "FC"
             	          label  = "#{path[:ctrl]}\n#{pathname}"
                        label += "\n#{path[:aportWWN][-9,9]}" unless path[:aportWWN] == "-" || path[:aportWWN].nil? || path[:aportWWN].empty?
                        edge = graph.add_edges(plexdata[:subdisks_graphnode] ,$vxdmp[dgdata[:dm][sd[:dmpdev]][:assoc]][:graphnode], :tailport => sd[:name], :label => label, :style => "dashed", :weight => 10 ) 
      	       #end
      	     end
              end
            end unless plexdata[:sd].nil?
         end unless dgdata[:pl].nil? || dgdata[:pl].empty?

         # unused subdisks - no association to a volume  or a plex
         dgdata[:sd].each do |sd|
            sd[:graphnode] = sd_graph.add_nodes("Subdisk\n#{sd[:name]}\n#{vxsize(sd[:size])}\nUnassociated", :style => "dashed", :shape => "box")
            edge = graph.add_edges(sd[:graphnode], dgdata[:graphnode]) 
            edge[:style] = "dashed"
            # Verbindung Subdisk -> dmpdev
            $vxdmp[dgdata[:dm][sd[:dmpdev]][:assoc]][:path].each do |pathname,path|
               $vxdmp[dgdata[:dm][sd[:dmpdev]][:assoc]][:associated] = :semi
               if path[:transport] == "FC"
             	    label  = "#{path[:ctrl]}\n#{pathname}"
                  label += "\n#{path[:aportWWN][-9,9]}" unless path[:aportWWN] == "-" || path[:aportWWN].nil? || path[:aportWWN].empty?
       	    edge = graph.add_edges(sd[:graphnode], $vxdmp[dgdata[:dm][sd[:dmpdev]][:assoc]][:graphnode], :tailport => sd[:name], :style => "dashed", :label => label, :weight => 10)
      	 end
            end unless $vxdmp[dgdata[:dm][sd[:dmpdev]][:assoc]].nil?
         end unless dgdata[:sd].nil? || dgdata[:sd].empty?

         # enabled plexes - working association to a volume
         dgdata[:v].each do |volname,voldata|
            voldata[:graphnode] = graph.add_nodes("Volume\n#{volname}\n#{vxsize(voldata[:size])}", :shape => "octagon")
            voldata[:graphnode][:shape] = "doubleoctagon" if voldata[:pl].count == 2
            voldata[:graphnode][:shape] = "tripleoctagon" if voldata[:pl].count > 2

            # Verbindung Diskgroup -> Volume
            unless voldata[:layered]
              edge=graph.add_edges(dgdata[:graphnode],voldata[:graphnode], :weight => 10)
              if voldata[:state] == "ENABLED"
                edge[:color] = "#000000"
                edge[:penwidth] = "1"
              end
            end

            plexlabels = voldata[:pl].inject([]) {|r,pl| r << "<#{pl[0]}> Plex\n#{pl[0]}\n#{vxsize(pl[1][:size])}" }
            voldata[:plexes_graphnode] = graph.add_nodes("plexes #{volname}", "shape" => "record", "label" => plexlabels.join("|") ) unless plexlabels.empty?

            # Verbindung Volume -> Plex
            edge = graph.add_edges(voldata[:graphnode],voldata[:plexes_graphnode], :weight => 10)
            edge[:color] = "#000000"
            edge[:penwidth] = "1"

            voldata[:pl].each do |plexname,plexdata|
               next if plexdata[:sd].nil? && !plexdata[:sv].nil? #  skip layered volumes
      	       subdisklabels = plexdata[:sd].inject([]) {|r,sd| r << "<#{sd[:name]}> Subdisk\n#{sd[:name]}\n#{vxsize(sd[:size])}"}
      	       plexdata[:subdisks_graphnode] = graph.add_nodes("subdisks #{plexname}", "shape" => "record", "label" => subdisklabels.join("|") ) unless subdisklabels.empty?

               # Verbindung Plex ->  Subdisk
               edge = graph.add_edges(voldata[:plexes_graphnode],plexdata[:subdisks_graphnode], :tailport => plexname, :weight => 10 )
               edge[:color] = "#000000"
               edge[:penwidth] = "1"

               plexdata[:sd].each do |sd|
      	         if $vxdmp[dgdata[:dm][sd[:dmpdev]][:assoc]]
      	           $vxdmp[dgdata[:dm][sd[:dmpdev]][:assoc]][:graphnode][:style]="filled"

                   # Verbindung Subdisk -> dmpdev
                   $vxdmp[dgdata[:dm][sd[:dmpdev]][:assoc]][:path].each do |pathname,path|
      		           #if path[:transport] == "FC"
                           $vxdmp[dgdata[:dm][sd[:dmpdev]][:assoc]][:associated] = :full
      		                 label  = "#{path[:ctrl]}\n#{pathname}"
      		                 label += "\n#{path[:aportWWN][-9,9]}" unless path[:aportWWN] == "-" || path[:aportWWN].nil? || path[:aportWWN].empty?
                           edge = graph.add_edges(plexdata[:subdisks_graphnode] ,$vxdmp[dgdata[:dm][sd[:dmpdev]][:assoc]][:graphnode], :tailport => sd[:name], :label => label, :weight => 10) 
      	                   if path[:state] == "enabled(a)" || path[:state] == "ENABLED(A)"
      		                   edge[:color] = "#000000"
      		                   edge[:penwidth] = "1"
                           end
      		           #end
      	           end
      	         else
      	           printf "### No LUN found for: %p\n", dgdata[:dm][sd[:dmpdev]][:assoc]
                end
               end unless plexdata[:sd].nil?

            end unless voldata[:pl].nil?
         end unless dgdata[:v].nil?

         dgdata[:dm].each do |dmname,dmdata|
           if $vxdmp[dmdata[:assoc]]
             # get lun-size via diskmedia-size
             $vxdmp[dmdata[:assoc]][:graphnode][:label]= "LUN\n#{dmname}\n#{$vxdmp[dmdata[:assoc]][:state]}\n#{vxsize(dmdata[:size])}\n#{$vxdmp[dmdata[:assoc]][:enclosure]}\n#{$vxdmp[dmdata[:assoc]][:'cab-sno']}"

             # connect unassociated luns with diskgroup
             if $vxdmp[dmdata[:assoc]][:associated].nil?
                $vxdmp[dmdata[:assoc]][:path].each do |pathname,path|
                   $vxdmp[dmdata[:assoc]][:associated] = :semi
      	     #if path[:transport] == "FC"
                     label  = "#{path[:ctrl]}\n#{pathname}"
      	       label += "\n#{path[:aportWWN][-9,9]}" unless path[:aportWWN] == "-" || path[:aportWWN].nil? || path[:aportWWN].empty?
                     edge = graph.add_edges(dgdata[:graphnode],$vxdmp[dmdata[:assoc]][:graphnode], :label => label, :style => "dashed" )
                   #end
                end
             end

             if $vxdmp[dmdata[:assoc]][:enclosure] == "DS8RZD1"
               if $vxdmp[dmdata[:assoc]][:associated] && $vxdmp[dmdata[:assoc]][:associated] == :full
                  $vxdmp[dmdata[:assoc]][:graphnode][:fillcolor]= "#00ffcc"
                  $vxdmp[dmdata[:assoc]][:graphnode][:style]="filled,rounded"
               else
                  $vxdmp[dmdata[:assoc]][:graphnode][:style]="dashed,rounded"
               end
             elsif
               if $vxdmp[dmdata[:assoc]][:associated] && $vxdmp[dmdata[:assoc]][:associated] == :full
                  $vxdmp[dmdata[:assoc]][:graphnode][:fillcolor]= "#ccff00"
                  $vxdmp[dmdata[:assoc]][:graphnode][:style]="filled"
               else
                  $vxdmp[dmdata[:assoc]][:graphnode][:style]="dashed"
               end
             end

           end
         end

      end

      # connect layered volumes
      $vxdg.each do |dgname,dgdata|
        dgdata[:v].each do |volname,voldata|
          voldata[:pl].each do |plexname,plexdata|
            if plexdata[:sd].nil? && !plexdata[:sv].nil? # layered volumes
              puts "### WARNING: Layered volume found: #{voldata[:name]} consisting of plex: #{plexname}"
              plexdata[:sv].each do |subvolume|
                layered_volume_name = subvolume[:name].gsub(/(.*\-)S(\d*)$/,"\\1L\\2")
                unless dgdata[:v][layered_volume_name][:graphnode].nil?
                  graph.add_edges(voldata[:plexes_graphnode],dgdata[:v][layered_volume_name][:graphnode])
                end
              end
            end
          end
        end unless dgdata[:v].nil?
      end

      # connect all unassociated dmpdevs with deported diskgroups if possible
      $vxdmp.each do |dmpname,dmpdata|
        if dmpdata[:associated].nil?
          unless dmpdata[:dg].nil?
            dgname = dmpdata[:dg]
            if $vxdg[dgname].nil?
               $vxdg[dgname] = {}
               $vxdg[dgname][:graphnode] = dg_graph.add_nodes("Diskgroup\n#{dgname}\nDeported", :shape => "oval")
            end
            graph.add_edges($vxdg[dgname][:graphnode],dmpdata[:graphnode])
          end
        end
      end
      graph.output(:png => "vxvm-#{$hostname}-#{Time.now.strftime('%Y%m%d%H%M')}.png")
    end  
  end
  
  def plot_for_host(hostname)
    #$marked_luns = %w( 0014 0015 0016 0017 010e 0117 0118 011a 0024 0025 0026 0027 0028 1500 1501 116d 116f 1170 1171 1172 1173 1174 0035 0036 0037 0038 011e 003c 003d 003e 003f 0040 0041 0042 0043 1500 1501 1502 1503 1504 1505 1506 1507 1508 1509 150a 150b 150c 150d 1076 1516 1517 1518 1077 1078 1079 )

    # vxprint -lp und type auswerten
    # später mal nutzen: vxprint -trL 

    channel_output=[]
    ssh_execute hostname, 
                ["hostname", "date", "vxdctl enable"],
                ["vxprint", "vxdisk -o alldgs list", "vxdmpadm list dmpnode all", "vxdmpadm getsubpaths"] do |channel,data|
      channel_output[channel] = data
    end

    # #puts YAML::dump($vxdmp)
    # #puts YAML::dump($vxdg)
    # #puts YAML::dump($vxenclosure)

    parse_vxdmpadm_dmpnodes channel_output[5]
    parse_vxdmpadm_paths channel_output[6]
    parse_vxprint channel_output[3]
    parse_vxdisk channel_output[4]
    plot_graphs
  end
  
end