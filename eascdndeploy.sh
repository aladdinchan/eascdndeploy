#!/usr/bin/env bash
#CDN deploy script for EAS client files.
#Author : CHEN JUN
#Date : 2021-01-10

#只支持在bash 4+环境中运行
if [[ ! -n $BASH ]] ; then
    echo "This script requires BASH. "
    echo 
    exit 1
elif [[ ${BASH_VERSINFO[0]} -lt 4 ]] ; then
    echo "This script requires BASH version 4+, your version is $BASH_VERSION."
    echo
    exit 1
fi

#帮助信息
function usage(){
    echo -e "\
CDN deploy script for EAS client files.

Usage:
./eascdndeploy.sh [Options] {Patch files | EAS home directories | EAS web sites}

Examples:
./eascdndeploy.sh -c /var/www/cdnroot PT1000268.zip
./eascdndeploy.sh -v -c /var/www/cdnroot PT*.zip
./eascdndeploy.sh -vt -c /var/www/cdnroot /kingdee
./eascdndeploy.sh -f jar,exe,dll -c /var/www/cdnroot https://abc.kdeascloud.com

This script uses the following commands to complete the work. 
md5sum or openssl, curl, mktemp, unzip, awk, sed, find, xargs, tr, sort, uniq, rm, cp, touch, etc.

Options:
  -c DIR    CDN root directory.  It must has easwebcache subdirectory.
  -f TYPES  File types to deploy, comma separated. default is '*' for all types.
  -a        Update access time of file if already deployed.
  -t        Test deploy and exit.
  -v        Verbose output.
  -h        Display help and exit.
"
}

#输出统计信息
function printsummary(){
    echo -e "Summary for $ARG :\n  \e[92m$COUNT_FILES_PROCESSED\e[0m file(s) have been processed, "
    if [ "$TEST" = "1" ] ; then
        if [ "$TOUCH" = "1" ] ; then
            echo -e "  \e[94m$COUNT_FILES_DEPLOYED\e[0m file(s) access time will be updated, "
        else
           echo -e "  \e[94m$COUNT_FILES_DEPLOYED\e[0m file(s) will be ignored, "
        fi
        echo -e "  \e[94m$COUNT_FILES_TODEPLOY\e[0m file(s) will be deployed. \n"
    else
        if [ "$TOUCH" = "1" ] ; then
            echo -e "  \e[94m$COUNT_FILES_DEPLOYED\e[0m file(s) access time have been updated, "
        else
           echo -e "  \e[94m$COUNT_FILES_DEPLOYED\e[0m file(s) have been ignored, "
        fi
        echo -e "  \e[94m$COUNT_FILES_TODEPLOY\e[0m file(s) have been deployed, "
        echo -e "  \e[91m$COUNT_FILES_FAILED\e[0m file(s) have been failed. \n"
    fi
}

#部署补丁文件PT*.zip中的EAS客户端文件到CDN目录
function deploypatchfile(){
    EAS_PATCHFILE="$1"
    if [ "${EAS_PATCHFILE##*.}" != "zip" ] ; then
        echo -e "\e[91m$EAS_PATCHFILE is not a EAS patch file.\e[0m\n"
        return
    fi

    #在当前目录创建一个临时目录，用于解压缩补丁文件。 macOS下的mktemp不支持 -p参数。
    TEMP_DIR="$(mktemp -d tmp.cdn.XXXXXXXXXX)"
    if [[ "$TEMP_DIR" = "" || ! -d "$TEMP_DIR" ]] ; then
        #临时目录创建异常
        echo -e "\e[91mCan not create temporary directory, aborted.\e[0m\n"
        return
    fi

    echo "Unzip $EAS_PATCHFILE to $TEMP_DIR/patchfiles ..."
    if [ "$VERBOSE" != "1" ] ; then
        #开启静默解压
        UNZIP_QUIET="-q"
    fi
    unzip $UNZIP_QUIET -d $TEMP_DIR/patchfiles $EAS_PATCHFILE Server/server/deploy/fileserver.ear/easWebClient/*
    if [[ $? -ne 0 && $? -ne 11 ]] ; then
        #解压缩失败。 11表示没有找到匹配的文件
        echo -e "\e[91mUnzip $EAS_PATCHFILE error. \e[0m"
    fi

    #部署解压的临时目录中的EAS客户端文件
    if [ -d "$TEMP_DIR/patchfiles/Server/server/deploy/fileserver.ear/easWebClient" ] ; then
        deploydirectory "$TEMP_DIR/patchfiles/Server/server/deploy/fileserver.ear/easWebClient"
    else
        echo -e "\e[93mThere is no EAS client file in $EAS_PATCHFILE .\e[0m\n"
    fi

    #删除临时目录
    if [[ "$TEMP_DIR" == *tmp.cdn* ]] ; then 
        #增加目录名判断的目的是为了避免理论上应该不会出现的误删，rm -rf会静默删除整个目录
        rm -rf "$TEMP_DIR"
    fi
}

#部署指定路径下的EAS客户端文件到CDN目录
function deploydirectory(){
    EAS_CLIENTDIR="$1"

    if [ ! -d "$EAS_CLIENTDIR" ] ; then
        #目录不存在
        echo -e "\e[91mTHe deploy directory for EAS client files \"$EAS_CLIENTDIR\" not exist.\e[0m\n"
        return
    fi

    #只处理bin/classloader/deploy/lib/metas目录及子目录下的文件
    SEARCH_PATHS=""
    if [ -d "$EAS_CLIENTDIR/bin" ] ; then SEARCH_PATHS="$SEARCH_PATHS $EAS_CLIENTDIR/bin" ; fi
    if [ -d "$EAS_CLIENTDIR/classloader" ] ; then SEARCH_PATHS="$SEARCH_PATHS $EAS_CLIENTDIR/classloader" ; fi
    if [ -d "$EAS_CLIENTDIR/deploy" ] ; then SEARCH_PATHS="$SEARCH_PATHS $EAS_CLIENTDIR/deploy" ; fi
    if [ -d "$EAS_CLIENTDIR/lib" ] ; then SEARCH_PATHS="$SEARCH_PATHS $EAS_CLIENTDIR/lib" ; fi
    if [ -d "$EAS_CLIENTDIR/metas" ] ; then SEARCH_PATHS="$SEARCH_PATHS $EAS_CLIENTDIR/metas" ; fi
    
    #生成文件名过滤参数形如: /\.jar$/ && /\.exe$/ && /\.dll$/。 必须以这些文件类型结尾。
    FILENAME_FILTER_AWK=$(echo "$FILETYPES" | tr ',' '\n' | xargs -I {} echo -n ' /\.{}$/ ||')
    #截掉最后多出的 || 注：bash 4.1.x不支持这样的语法："${FILENAME_FILTER_AWK::-2}"
    FILENAME_FILTER_AWK="${FILENAME_FILTER_AWK::${#FILENAME_FILTER_AWK}-2}"

    #查找指定扩展名的文件，生成需要部署的文件名数组。如果用$()方式执行会出错，加\转义也不行。
    CLIENTFILES_NAME=`find $SEARCH_PATHS -type f | awk "$FILENAME_FILTER_AWK"`
    CLIENTFILES_NAME=($CLIENTFILES_NAME)

    #计数器：处理文件总数，已部署数量，本次部署数量，失败数量。
    COUNT_FILES_PROCESSED=${#CLIENTFILES_NAME[@]}
    COUNT_FILES_DEPLOYED=0
    COUNT_FILES_TODEPLOY=0
    COUNT_FILES_FAILED=0
 
    #遍历数组，处理每一个文件
    i=0
    while [ $i -lt ${#CLIENTFILES_NAME[@]} ] 
    do
        #取文件名并计算对应MD5
        FILE_NAME="${CLIENTFILES_NAME[$i]}"
        FILE_MD5="$($CMD_MD5SUM $FILE_NAME | awk '{print $1}')"

        #CDN上文件名变为路径名，文件的MD5值则作为文件名。
        CDN_FILE_DIR="$CDN_ROOTDIR/easwebcache/${FILE_NAME:${#EAS_CLIENTDIR}}"
        CDN_FILE_NAME="$CDN_FILE_DIR/$FILE_MD5"
        if [ ! -d "$CDN_FILE_DIR" ] ; then
            #路径不存在则创建， -t 测试模式除外
            if [ "$TEST" != "1" ] ; then 
                mkdir -p "$CDN_FILE_DIR" 
            fi
        fi

        if [ -f "$CDN_FILE_NAME" ] ; then
            #文件已存在，跳过
            let COUNT_FILES_DEPLOYED++

            if [ "$TOUCH" = "1" ] ; then
                #更新文件最后访问时间
                echo -ne "File \"$FILE_NAME\" already deployed, ..."
                if [ "$TEST" = "1" ] ; then
                    echo -e "\e[94m access time will be updated.\e[0m" ;
                else
                    #非测试模式才真正更新
                    touch -ac "$CDN_FILE_NAME"
                    echo -e "\e[94m access time updated.\e[0m" ; 
                fi
            elif [ "$VERBOSE" = "1" ] ; then 
                echo -ne "File \"$FILE_NAME\" already deployed, ..."
                if [ "$TEST" = "1" ] ; then
                    #测试模式
                    echo -e "\e[94m will be ignored.\e[0m" ; 
                else
                    #忽略已部署文件
                    echo -e "\e[94m ignored.\e[0m" ; 
                fi
            fi
        else
            #未部署过的新文件，复制到CDN路径
            let COUNT_FILES_TODEPLOY++
            echo -n "File \"$FILE_NAME\" is new, ... "
            if [ "$TEST" != "1" ] ; then
                cp $FILE_NAME $CDN_FILE_NAME
                echo -e "\e[92mdeployed.\e[0m"
            else
                # -t 测试模式
                echo -e "\e[92mwill be deployed.\e[0m"
            fi
        fi
        #下一个文件
        let i++
    done

    #输出统计信息
    printsummary
}

#部署指定EAS网站的EAS客户端文件到CDN目录
function deployeaswebsite(){
    #EAS网站URL
    EAS_WEBSITE="$1"

    #测试EAS网站能否正常访问.
    echo -e "Testing eas web site: $EAS_WEBSITE ..."
    curl -s $EAS_WEBSITE/easupdater/JnlpVersion > /dev/null
    if [ $? -ne 0 ] ; then
        echo -e "\e[91mCan not access eas web site.\e[0m\n"
        return
    fi

    #生成文件名过滤参数形如: /\.jar'[[:space:]]/ && /\.exe'[[:space:]]/ && /\.dll'[[:space:]]/。
    FILENAME_FILTER_AWK=$(echo "$FILETYPES" | tr ',' '\n' | xargs -I {} echo -n " /\.{}'[[:space:]]/ ||")
    #截掉最后多出了的 || 。 注：bash 4.1.x不支持这样的语法："${FILENAME_FILTER_AWK::-2}"
    FILENAME_FILTER_AWK="${FILENAME_FILTER_AWK::${#FILENAME_FILTER_AWK}-2}"

    #从eas.jnlp解析出需要部署的文件及MD5
    echo -e "Downloading and processing the file: $EAS_WEBSITE/easupdater/eas.jnlp ..."
    JNLP_FILES=$(curl -s -L $EAS_WEBSITE/easupdater/eas.jnlp |
    sed 's/\(<jar\)/\
    \1/g; s/\(<nativelib\)/\
    \1/g' |
    awk "( /<jar/ || /<nativelib/ ) && ( $FILENAME_FILTER_AWK )" |
    sed "s/\(.*\)href='\(.*\)'\(.*\)md5Version=\"\([^\"]*\)\"\(.*\)/\2\t\4/g")

    #从resource.lst解析出需要部署的文件及MD5
    echo -e "Downloading and processing the file: $EAS_WEBSITE/easupdater/resource.lst ..."
    RESOURCELST_FILES=$(curl -s -L $EAS_WEBSITE/easupdater/resource.lst |
    sed 's/\(<jar\)/\
    \1/g' |
    awk "( /<jar/ ) && ( $FILENAME_FILTER_AWK )" |
    sed "s/\(.*\)href='\(.*\)'\(.*\)md5Version=\"\([^\"]*\)\"\(.*\)/\2\t\4/g")

    #过滤出需要部署的文件类型并合并重复的文件。若没有中间的\n，会导致JNLP_FILES的最后一行和RESOURCELST_FILES的第一行合并，影响结果。
    MERGED_FILES=`echo -e "$JNLP_FILES\n$RESOURCELST_FILES" | sort | uniq`
    
    #生成需要部署的文件名数组以及对应的MD5数组
    CLIENTFILES_NAME=($(echo -e "$MERGED_FILES" | awk '{print $1}'))
    CLIENTFILES_MD5=($(echo -e "$MERGED_FILES" | awk '{print $2}'))

    #计数器：处理文件总数，已部署数量，本次部署数量，失败数量。
    COUNT_FILES_PROCESSED=${#CLIENTFILES_NAME[@]}
    COUNT_FILES_DEPLOYED=0
    COUNT_FILES_TODEPLOY=0
    COUNT_FILES_FAILED=0
 
    #遍历数组，处理每一个文件
    i=0
    while [ $i -lt ${#CLIENTFILES_NAME[@]} ] 
    do
        #取文件名和对应MD5
        FILE_NAME="${CLIENTFILES_NAME[$i]}"
        FILE_MD5="${CLIENTFILES_MD5[$i]}"

        #CDN上文件名变为路径名，文件的MD5值则作为文件名。
        CDN_FILE_DIR="$CDN_ROOTDIR/easwebcache/$FILE_NAME"
        CDN_FILE_NAME="$CDN_FILE_DIR/$FILE_MD5"
        if [ ! -d "$CDN_FILE_DIR" ] ; then
            #路径不存在则创建， -t 测试模式除外
            if [ "$TEST" != "1" ] ; then 
                mkdir -p "$CDN_FILE_DIR" 
            fi
        fi

        if [ -f "$CDN_FILE_NAME" ] ; then
            #文件已存在，跳过
            let COUNT_FILES_DEPLOYED++

            if [ "$TOUCH" = "1" ] ; then
                #更新文件最后访问时间
                echo -ne "File \"$FILE_NAME\" already deployed, ..."
                if [ "$TEST" = "1" ] ; then
                    echo -e "\e[94m access time will be updated.\e[0m" ;
                else
                    #非测试模式才真正更新
                    touch -ac "$CDN_FILE_NAME"
                    echo -e "\e[94m access time updated.\e[0m" ; 
                fi
            elif [ "$VERBOSE" = "1" ] ; then 
                echo -ne "File \"$FILE_NAME\" already deployed, ..."
                if [ "$TEST" = "1" ] ; then
                    #测试模式
                    echo -e "\e[94m will be ignored.\e[0m" ; 
                else
                    #忽略已部署文件
                    echo -e "\e[94m ignored.\e[0m" ; 
                fi
            fi
        elif [ "$TEST" = "1" ] ; then
            # -t 测试模式
            let COUNT_FILES_TODEPLOY++
            echo -e "File \"$FILE_NAME\" is new, ... \e[92mwill be downloaded and deployed.\e[0m"
        else
            #未部署过的新文件，需要从EAS服务器下载并部署
            echo -n "File \"$FILE_NAME\" is new, downloading ... "
            CURL_RESULTS=$(curl -sS -L --write-out "%{time_total} %{http_code}" -o $CDN_FILE_NAME $EAS_WEBSITE/easWebClient/$FILE_NAME 2>&1)
            if [ $? -eq 0 ] ; then
                #文件下载成功
                CURL_INFOS=($CURL_RESULTS) #转换为数组
                echo -n -e "finished, elapsed time: ${CURL_INFOS[0]}s. "

                if [ ! -f $CDN_FILE_NAME ] ; then
                    #下载成功，文件却没有生成，通常是文件长度为0导致的。
                    let COUNT_FILES_FAILED++
                    echo -e "\e[91mdeploy failed with http code ${CURL_INFOS[1]}. may be a zero length file. \e[0m"
                else
                    #校验部署的文件MD5值，如果不正确，则删除。
                    MD5_VALUE="$($CMD_MD5SUM $CDN_FILE_NAME | awk '{print $1}')"
                    if [ "$MD5_VALUE" = "$FILE_MD5" ] ; then
                        let COUNT_FILES_TODEPLOY++
                        echo -e "\e[92mdeployed. \e[0m"
                    else
                        let COUNT_FILES_FAILED++
                        echo -e "\e[91mdeploy failed by wrong md5 hash value. \e[0m"
                        rm -f $CDN_FILE_NAME
                    fi
                fi
            else
                let COUNT_FILES_FAILED++
                #执行异常时，$CURL_RESULTS会包含错误信息。 2>&1将错误重定向到STDOUT
                #实际测试会输出两行，最后一行：%{time_total} %{http_code}
                #curl: (7) Failed connect to eascloud.kingdee.com:80; 拒绝连接
                #0.004 000
                CURL_INFOS=($(echo -e "$CURL_RESULTS" | tail -n 1))
                ERROR_MSG=$(echo -e "$CURL_RESULTS" | head -n 1)
                echo -e "\e[91mfailed. $ERROR_MSG\e[0m, elapsed time: ${CURL_INFOS[0]}s."
                #如果下载出错，文件很可能损坏，需要删除下载的文件，下次执行再重新部署即可
                if [ -f $CDN_FILE_NAME ] ; then
                    rm -f $CDN_FILE_NAME
                fi
            fi
        fi
        #下一个文件
        let i++
    done

    #输出统计信息
    printsummary
}

#解析所有命令行选项
while getopts :c:f:atvh opt
do
    case $opt in
        c) CDN_ROOTDIR=$OPTARG ;;
        f) FILETYPES=$OPTARG ;;
        a) TOUCH=1 ;;
        t) TEST=1 ;;
        v) VERBOSE=1 ;;
        h)
            usage
            exit 0
            ;;
        ?)
            echo "Invalid option: -$OPTARG"
            usage
            exit 1
            ;;
    esac
done

#参数有效性检查
if [ "$CDN_ROOTDIR" = "" ] ; then
    usage
    exit 1
elif [[ "$CDN_ROOTDIR" =~ [[:space:]] ]] ; then
    #目录名不能包含空格
    echo -e "\e[91mError: CDN root directory \"$CDN_ROOTDIR\" must not include space characters.\e[0m\n"
    exit 1
elif [ ! -d "$CDN_ROOTDIR/easwebcache" ] ; then
    echo -e "\e[91mError: EAS CDN directory \"$CDN_ROOTDIR/easwebcache\" not exist.\e[0m\n"
    exit 1
fi
if [ "$FILETYPES" = "" ] ; then
    #缺省部署的文件类型
    FILETYPES="*"
fi

#查找可以计算MD5 hash的命令，如果找不到，退出程序。
CMD_MD5SUM="$(which md5sum)"
if [ "$CMD_MD5SUM" = "" ] ; then
    CMD_MD5SUM="$(which openssl)"
    if [ "$CMD_MD5SUM" = "" ] ; then
        echo -e "\e[91mMD5 digest command not found . Please install md5sum or openssl and try again.\e[0m\n"
        exit 1
    else
        CMD_MD5SUM="$CMD_MD5SUM dgst -md5 -r"
    fi
fi

#计数器：处理文件总数，已部署数量，本次部署数量，失败数量。
#如下几个变量用于统计多个部署任务的汇总信息。
COUNT_FILES_PROCESSED_TOTAL=0
COUNT_FILES_DEPLOYED_TOTAL=0
COUNT_FILES_TODEPLOY_TOTAL=0
COUNT_FILES_FAILED_TOTAL=0
COUNT_TASKS_RAN=0

#移动到选项后面的参数
shift $((OPTIND-1))

#输出参数信息
echo -e "CDN root directory: \"$CDN_ROOTDIR\". \nFile type(s): \"$FILETYPES\""
if [ "$TEST" = "1" ] ; then echo -e "Test mode." ; fi
if [ "$VERBOSE" = "1" ] ; then echo -e "Verbose output." ; fi
echo -e "Argument(s): \"$*\"\n"

#对每个参数分别进行检查，确定参数种类并执行对应部署逻辑。
while [ "$1" != "" ] ; do
    ARG="$1"
    
    if [[ "$ARG" =~ [[:space:]] ]] ; then
        #参数不能包含空格
        echo "Deploy from : $ARG ..."
        echo -e "\e[91mError: File, directory and url must not include space characters. skipped.\e[0m\n"
        shift
        continue
    fi

    #如下几个变量会在部署函数中改变，如果某个参数异常导致任务没有被执行，下面的变量值会是上一个成功任务的值。
    #如果不在此处重置，可能会导致双计上次成功执行的任务。
    COUNT_FILES_PROCESSED=0
    COUNT_FILES_DEPLOYED=0
    COUNT_FILES_TODEPLOY=0
    COUNT_FILES_FAILED=0

    if [ -d "$ARG" ] ; then
        #参数是目录，将被认定为EAS home目录.
        #从EAS目录搜索客户端文件并部署到CDN路径
        echo "Deploy from eas directory : $ARG ..."
        deploydirectory "$ARG/eas/server/deploy/fileserver.ear/easWebClient"
        let COUNT_TASKS_RAN++
    elif [ -f "$ARG" ] ; then
        #参数是文件，将被认定为EAS补丁文件.
        #从EAS补丁文件中提取客户端文件并部署到CDN路径
        echo "Deploy from eas patch file : $ARG ..."
        deploypatchfile "$ARG"
        let COUNT_TASKS_RAN++
    elif [[ "$ARG" == http://* ||  "$ARG" == https://* ]] ; then
        #参数是URL，将被认定为EAS网站.
        #从EAS网站获取文件并部署到CDN路径
        echo "Deploy from eas website : $ARG ..."
        deployeaswebsite "$ARG"
        let COUNT_TASKS_RAN++
    else
        #参数不正确，任务未执行
        echo "Deploy from : $ARG ..."
        echo -e "\e[91m\"$ARG\" is none of .zip file, EAS home directory or EAS web site. skipped.\e[0m\n"
    fi

    #汇总计数器
    let COUNT_FILES_PROCESSED_TOTAL+=COUNT_FILES_PROCESSED
    let COUNT_FILES_DEPLOYED_TOTAL+=COUNT_FILES_DEPLOYED
    let COUNT_FILES_TODEPLOY_TOTAL+=COUNT_FILES_TODEPLOY
    let COUNT_FILES_FAILED_TOTAL+=COUNT_FILES_FAILED

    #处理下一个参数
    shift
done

if [ $COUNT_TASKS_RAN -eq 0 ] ; then
    #没有一个部署任务被执行，参数不正确
    echo -e "\e[91mNo deployment tasks have been performed, please check the argument(s).\e[0m\n"
    exit 1
elif  [ $COUNT_TASKS_RAN -ge 2 ] ; then
    #执行的任务数有2个或以上时，才需要汇总统计。
    echo "------------------------------------"
    #如下赋值是为了重用printsummary函数
    ARG="ALL"
    let COUNT_FILES_PROCESSED=COUNT_FILES_PROCESSED_TOTAL
    let COUNT_FILES_DEPLOYED=COUNT_FILES_DEPLOYED_TOTAL
    let COUNT_FILES_TODEPLOY=COUNT_FILES_TODEPLOY_TOTAL
    let COUNT_FILES_FAILED=COUNT_FILES_FAILED_TOTAL
    #输出汇总统计信息
    printsummary
fi

#end