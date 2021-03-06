# EAS客户端文件CDN部署脚本
提取EAS补丁文件、EAS服务器目录、以及EAS网站中的客户端文件，并按照EAS CDN更新所约定的目录及文件格式部署到指定目录。可将部署目录直接发布为CDN源站，或者同步到外部CDN网站上。<br/>
<br/>

## 安装和运行
```bash
curl -sSOL https://raw.githubusercontent.com/aladdinchan/eascdndeploy/main/eascdndeploy.sh
chmod +x eascdndeploy.sh

./eascdndeoploy.sh ...
```
<br/>

## 环境要求
要求bash 4+版本，并依赖若干命令和工具，参见后面的说明。<br/>
在CentOS 6/7/8、macOS 11.1中验证通过。<br/>
<br/>
macOS自带的bash版本如果较低，可通过`brew`安装新版本：<br/>
```bash
#安装brew包管理工具
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
#安装最新版本的bash
brew install bash

#用新版本bash执行脚本
/usr/local/bin/bash ./eascdndeoploy.sh ...
```
<br/>

## 用法及参数
./eascdndeploy.sh&emsp;[选项]&emsp;{补丁文件&nbsp;|&nbsp;EAS目录&nbsp;|&nbsp;EAS网站}<br/>
<br/>
支持一次传多个参数。<br/>
<br/>
这个脚本会用到如下命令或工具，如果缺少将不能正常工作。<br/>
md5sum 或 openssl, curl, mktemp, unzip, awk, sed, find, xargs, tr, sort, uniq, rm, cp, touch 等。<br/>
Linux：需要GNU awk 3+ 版本。<br/>
|选项|说明|
|:----|:--------|
|-c DIR|CDN根目录。其必须有easwebcache子目录，文件将部署到该子目录下。|
|-f TYPES|要部署的文件类型，默认为`'*'`部署所有类型的文件。|
|-t|测试模式。不实际部署文件，可用于检查会有多少文件将会部署。|
|-a|更新已部署文件的最后访问时间。|
|-v|输出详细信息。|
|-h|显示命令帮助。|
<br/>

## 示例
1. 提取EAS补丁PT1000268.zip中的EAS客户端文件并部署到`/home/eascdn`目录下的`easwebcache`子目录中。<br/>
```bash
./eascdndeploy.sh -c /home/eascdn PT1000268.zip
```
2. 提取当前目录下所有PT开头的.zip中的EAS客户端文件并部署，-v 输出详细执行信息。<br/>
```bash
./eascdndeploy.sh -v -c /home/eascdn PT*.zip
```
3. 提取EAS安装目录`/kingdee`中的客户端文件并测试是否需要部署，输出详细执行信息。<br/>
```bash
./eascdndeploy.sh -vt -c /home/eascdn /kingdee
```
4. 提取EAS网站`https://abc.kdeascloud.com`中的客户端文件并部署，已部署的文件更新其最后访问时间。<br/>
```bash
./eascdndeploy.sh -a -c /home/eascdn https://abc.kdeascloud.com
```
5. 提取EAS网站`https://abc.kdeascloud.com`中扩展名为`jar、exe、dll、zip`的客户端文件并部署。<br/>
```bash
./eascdndeploy.sh -f jar,exe,dll,zip -c /home/eascdn https://abc.kdeascloud.com
```
<br/>

## 搭建CDN源站
CDN源站只需要提供静态文件下载服务即可，功能简单，部署也很容易，下面以`nginx`为例，并将`/home/eascdn`路径作为CDN源站的根路径。
1. 创建目录及`filetypes`文件<br/>
```bash
mkdir -p /home/eascdn/easwebcache
echo "jar;exe;dll;bat;xml;zip;properties;vmoptions;js;css;png;jpg;ico;gif" > /home/eascdn/easwebcache/filetypes
```
<br/>

2. 增加`nginx`配置文件，提供文件下载服务<br/>
新建配置文件`/etc/nginx/conf.d/eascdn.conf`，并添加如下配置信息。然后重启`nginx`服务，让配置生效。`service nginx restart` <br/>
```conf
server {
    listen       80;
    server_name  cdn-src.kdeascloud.com;   # 请替换为实际使用的域名

    # 路径：/home/eascdn/easwebcache
    location /easwebcache {
        root /home/eascdn;
        #autoindex on;  # 若希望浏览器可遍历文件，请去掉注释
        charset utf-8;
    }
}
```
<br/>

3. 安装脚本及日常部署<br/>
安装方法见：[安装和运行](#安装和运行) ，部署示例见：[示例](#示例)。
假定安装到`/home/eascdn`路径下，部署EAS网站`https://abc.kdeascloud.com`中的客户端文件命令如下。
```bash
cd /home/eascdn
./eascdndeploy.sh -c . https://abc.kdeascloud.com
```
<br/>

4. 实用单行脚本<br/>
```bash
cd /home/eascdn

#找出所有文件名与其MD5值不一致的那些文件（必须删除），-name参数限定文件名必须是MD5值。脚本执行中断或磁盘空间不足可能引发这种情况。
find easwebcache/*/ -type f -name "`printf "%0.s[a-f0-9]" {1..32}`" -exec md5sum {} \; | awk '! index($2,$1)'

#找出180天内没有被访问（下载）过的文件，并列出文件及最后访问时间。如果空间占用过大，考虑清理这些文件。
#两者差异：前者每找到一个文件就执行命令，后者会找到多个文件后分批传递给ls -lu。 后者输出格式更友好。
find easwebcache/*/ -type f -atime +180 -name "`printf "%0.s[a-f0-9]" {1..32}`" -exec ls -lu {} \;
find easwebcache/*/ -type f -atime +180 -name "`printf "%0.s[a-f0-9]" {1..32}`" -exec ls -lu {} +

#根据文件数量对目录进行排序，列出最多的10个目录，数量过多的话需要分析原因并考虑清理。（macOS不支持 -printf）
find easwebcache/*/ -type f -printf '%h\n' | uniq -c | sort -nr | head -n 10
find easwebcache/*/ -type f | sed 's/\/[^/]*$//g' | uniq -c | sort -nr | head -n 10
```
<br/>

## EAS更新机制
缺省情况下，EAS会启用局域网P2P更新，当P2P不可用或者更新失败时，如果已开启CDN更新选项（默认关闭），会尝试从约定或者指定的CDN站点上更新文件，如果依然失败，最终会从EAS服务器上直接下载。<br/>
<br/>

## 如何开启CDN更新
请按如下两个步骤来开启客户端CDN更新：<br/>
1、服务端配置CDN相关参数。<br/>
修改EAS实例配置文件，集群环境需要修改每个实例。`${EAS_HOME}/eas/server/profiles/server*/config/portalConfig/resourceSet.properties`. <br/>
增加如下两行参数: <br/>
`CDN_URL=http://cdn.kingdee.com/easwebcache/` <br/>
`CDN_FORCE_ENABLE=false` <br/>
<br/>
**CDN_URL**，指定CDN网站地址，注意地址最后的 “/” 不能少，请设置为自行搭建的CDN服务器网址。如果不设置此参数，默认为`http://cdn.kingdee.com/easwebcache/`，此网站目前并不可用。<br/>
**CDN_FORCE_ENABLE**，是否强制所有客户端开启CDN更新，默认关闭。开启后，所有客户端自动开启CDN更新，客户端的相关选项无效。<br/>
<br/>
2、客户端开启CDN更新。<br/>
打开EAS服务器连接设置工具`set-url`，勾选 **CDN下载** 选项。<br/>
或者直接修改`set-client-env.bat` <br/>
`SET ENABLE_CDN=true` <br/>
<br/>

## CDN网站目录及文件格式
为了同时支持多套EAS环境的客户端访问同一个CDN网站，以及避免CDN服务商的边缘节点缓存时效控制机制带来的不一致问题，CDN网站目录及文件格式设计上和EAS客户端存在差异。<br/>
<br/>
**规则**：保持原始文件相对目录不变，原来的文件名变成目录名，而文件则以其MD5值则作为文件名放入相应目录中。<br/>
<br/>
例：客户端文件 `eas/client/lib/common/bos/bosframework.jar` <br/> 

若从服务器下载，地址为：<br/>
`http://${SERVER_NAME}/easWebClient/lib/common/bos/bosframework.jar` <br/>
若从前面配置的CDN网站下载，地址则为：<br/>
`http://cdn.kingdee.com/easwebcache/lib/common/bos/bosframework.jar/aa52ec0ad5d1ffb5487c265eefa3554d` <br/>
<br/>
如此设计的好处是支持单个文件的多版本并存，且每个文件的内容永远不会变化，不存在CDN缓存刷新问题。<br/>
<br/>
`filetypes`文件：在CDN_URL对应目录下必须有此文件，单行文本，内容为允许从该CDN网站更新的文件扩展名，用分号; 分隔。
```
jar;exe;dll;bat;xml;zip;properties;vmoptions;js;css;png;jpg;ico;gif
```
客户端在启用CDN更新后，会从CDN网站获取`filetypes`（地址形如`http://cdn.kingdee.com/easwebcache/filetypes`）并解析其中包含的文件类型。只有类型匹配的文件，才会从CDN网站下载。
<br/>