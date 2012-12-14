require 'graphviz'
require 'yaml'
require 'rcommand'
require 'gnegraph'

module VXGraph
  
  include RCommand
  include GneGraph
  include GneGraph::Representation::Graphiz
        
  def vxsize(size) 
    sprintf("%2.2f GB", size.to_i * 512 / (1024*1024*1000))
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

  def plot_for_host(options)
    #$marked_luns = %w( 0014 0015 0016 0017 010e 0117 0118 011a 0024 0025 0026 0027 0028 1500 1501 116d 116f 1170 1171 1172 1173 1174 0035 0036 0037 0038 011e 003c 003d 003e 003f 0040 0041 0042 0043 1500 1501 1502 1503 1504 1505 1506 1507 1508 1509 150a 150b 150c 150d 1076 1516 1517 1518 1077 1078 1079 )
    # vxprint -lp und type auswerten
    # später mal nutzen: vxprint -trL 
    
    g = graph :title => "Veritas-Disklayout fuer #{options[:host]}", :truecolor => false, :rankdir => "BT" do |layout|
      rcommand options.merge!({:debug => true, :stdout => false}) do
        add_group do
          add_command :cmdline => "hostname"
          add_command :cmdline => "date"
          add_command :cmdline => "vxdctl enable"
        end
        add_group :order => :parallel do
          dgname   = nil
          volname  = nil
          plexname = nil
          add_command :id => :vxprint,  :cmdline => "vxprint" do |line|
            if line =~ /^dg\s+(\S+)\s+(\S+)\s+.*/
              layout.add_node :id => "dg_#{dgname = $1}", :title => "DG: #{dgname}", :assoc => $2, :goptions => {:shape => "oval"}
            end
            
            if line =~ /^dm\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)/
               diskmedia = layout.add_node :id => "dm_#{$1}", :title => "DM: #{$1}", :assoc => $2, :size => $4, :dg => dgname, :goptions => {:shape => "polygon"}
               layout.add_edge :source => diskmedia, :target => layout.node("dg_#{dgname}"), :weight => 5, :style => "dashed"
            end
            
            if line =~ /^v\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+.*/
               volname = $1
               vol = {:assoc => $2, :size => $4, :dg => dgname, :type => $2, :state => $3, :size => $4, :condition => $6}
               layered = (volname =~ /.*-L\d*$/ && volname.gsub(/(.*)-L(\d*)$/,"\\1") == subvolumename.gsub(/(.*)-S(\d*)$/,"\\1")) ? true : false
               volume = layout.add_node({:id => "vol_#{volname}", :title => "VOL: #{volname}", :goptions => {:shape => "octagon"}}.merge!(vol).merge!(:layered => layered))
               layout.add_edge :source => volume, :target => layout.node("dg_#{dgname}"), :weight => 5, :style => "dashed"
            end

            if line =~ /^pl\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+.*/
               plexname = $1
               plex = {:name => plexname, :assoc => $2, :state => $3, :size => $4, :condition => $6}
               if plex[:state] == "ENABLED"
                  # $vxdg[dgname][:v][volname][:pl] = {} if $vxdg[dgname][:v][volname][:pl].nil?
                  # $vxdg[dgname][:v][volname][:pl][plexname] = plex
                  # printf "### Plex %p\n", plex
               else
                  # $vxdg[dgname][:pl] = {} if $vxdg[dgname][:pl].nil?
                  # $vxdg[dgname][:pl][plexname] = plex
                  printf "### WARNING Following Plex is disabled: %p\n", plex
               end
               plex = layout.add_node({:id => "pl_#{plexname}", :title => "PL: #{plexname}",  :goptions => {:style => "dashed", :shape => "box"}}.merge!(plex))
               layout.add_edge :source => plex, :target => layout.node("dg_#{dgname}"), :weight => 5, :style => "dashed"
            end
            
           if !plexname.nil? && line =~ /^sd\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+.*/
              sdname = $1
              sd = {:assoc => $2, :state => $3, :size => $4} 
              if $1 =~ /^(\S+)-(\S+)$/
                sd[:dmpdev]=$1
              end
              subdisk = layout.add_node({:id => "sd_#{sdname}", :title => "SD: #{sdname}", :dg => dgname,  :goptions => {}}.merge!(sd))
              layout.add_edge :source => subdisk, :target => layout.node("dg_#{dgname}"), :weight => 5, :style => "dashed"
                # Disabled plexes are not associated to a volume - instead they are associated to a diskgroup - now associate all subdisk too
                # unless $vxdg[dgname][:pl].nil? || $vxdg[dgname][:pl][plexname].nil?
                #   $vxdg[dgname][:pl][plexname][:sd] = [] if $vxdg[dgname][:pl][plexname][:sd].nil?
                #   $vxdg[dgname][:pl][plexname][:sd] << sd
                # else
                #   # unused subdisks - no association to a volume or a plex
                #   printf "### WARNING: UNUSED SUBDISK: %p \n", sd
                #   $vxdg[dgname][:sd] = [] if $vxdg[dgname][:sd].nil?
                #   $vxdg[dgname][:sd] << sd
                # end
            end
            
          end
          add_command :id => :vxdisk,   :cmdline => "vxdisk -o alldgs list" do |line|
            if line =~ /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+).*$/
              dmpdev = $1
              diskgroup = $4
              if layout.node("dm_#{dmpdev}").nil? && diskgroup =~ /\((.*)\)/
                layout.add_node :id => "dm_#{dmpdev}", :title => "DM: #{dmpdev}", :dg => $1
              end
            end
          end
          # add_command :id => :dmpnode,  :cmdline => "vxdmpadm list dmpnode all" do |line|
          #             if line =~ /^(\S+)\s+=\s+(.*)$/
          #               dmpdev = $2  if $1 == "dmpdev"
          #               #printf "### WARNING Following dmpdev is %p: %p\n", $2, $vxdmp[dmpdev] if $1 == "state" && $2 != "enabled"
          #               unless dmpdev.nil? || ["###path"].include?($1)
          #                 if $1 == "path"
          #                   pathinfo = $2
          #                   if pathinfo =~ /(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)$/
          #                     unless layout.node("dm_#{dmpdev}").nil?
          #                       printf "#{dmpdev}: %p\n", {:state => $2, :type => $3, :transport => $4, :ctrl => $5, :hwpath => $6, :aportID=> $7, :aportWWN => $8, :attr => $9 }
          #                     else
          #                       puts dmpdev
          #                     end
          #                   else
          #                     puts "### ERROR reading path-info: #{pathinfo}"
          #                   end
          #                 else
          #                   #puts "not path: #{$1} #{$2}"
          #                  #$vxenclosure[$2] = {:name => $2} if $1 == "enclosure" && $vxenclosure[$2].nil?
          #                  #$vxdmp[dmpdev]={} if $vxdmp[dmpdev].nil?
          #                  #$vxdmp[dmpdev][$1.to_sym] = $2
          #                 end
          #               else
          #               end
          #             end
          #           end
          add_command :id => :subpaths, :cmdline => "vxdmpadm getsubpaths" do |line|
            if line[0] != "#" && line =~ /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+).*$/
              dmpdev = $4 
              if dmpdev != "DMPNODENAME" #&& ($vxdmp[dmpdev].nil? || $vxdmp[dmpdev][:path][$1].nil?)
                 unless layout.node("dm_#{dmpdev}").nil?
                   layout.node("dm_#{dmpdev}").options[:enclosure] = $5
                   layout.node("dm_#{dmpdev}").options[:path] = {:state => $2, :type => $3, :ctrl => $6, :attr => $7}
                 end
              end
            end
          end
        end
      end
    end
    puts g.to_s(:include_children => true)
    plot(g,"test.png")
  end
  
end