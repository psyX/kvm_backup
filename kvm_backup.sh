#!/bin/bash
# скрипт для бэкапа lvm томов для виртуальных машин libvirtd
# 
# восстановление
# читаем файл *.lvdisplay и создаем новый том с таким же размером
# из файла *.xml создаем новую виртуальную машину (если нужно исправляем путь к тому lvm)
# восстанавливаем данные диска:
# dd if=*.raw.gz | gzip -dc | dd of=/dev/vg/lv
# если есть файл *.state то делаем 
# virsh restore *.state 
# иначе просто запускаем виртуальную машину через virsh start domain
#


#
# backup_dir - директория куда будут сохранены образы дисков
#
backup_dir="/mnt/raid/backup/kvm"

#
# exclude_vm_regexp - регулярное выражение содержащее имя виртуальной машины для исключения из списка на резервное копирование
#
exclude_vm_regexp="new|test|^dbpg$"

#
# exclude_lv_regexp - регулярное выражение содержащее имя lvm тома для исключения из списка на резервное копирование
#
exclude_lv_regexp="^$"

#
# backup_date - формат даты, который будет включен в имя файла резервной копии
#
backup_date=`date +%Y-%m-%d-%H-%M-%S`

#
# lv_suffix - суффикс для имени снэпшота lvm тома
#
lv_suffix="-backup2347"

#
# lv_backup_list - файл списка lvm томов для резервной копии
#
lv_backup_list="/tmp/lv_backup_list"



function msg {
    case $1 in
        0)
            t="INFO: "
            ;;
        1)
            t="WARNING: "
            ;;
        2)
            t="ERROR: "
            ;;
        *)
            t="INFO: "
    esac

    echo "$t $2"
    #logger -i -t $0 "starting backup VMs..."
}

msg 0 "Starting VMs backup, at $backup_date"

# очищаем список томов для бэкапа
cat /dev/null > $lv_backup_list


# первый параметр имя виртуальной машины
arg_vm="$1"
if [ -z "$arg_vm" ]; then
    arg_vm="."
fi

# идем циклом по всем вм
virsh list --all | tail -n+3 | sed '/^$/d' | grep "$arg_vm" | while read m; do
    # берем имя и текущий статус вм
    vm_name=`echo $m | awk '{print $2}'`;
    vm_state=`echo $m | awk '{print $3 $4}'`
    
    # заполним переменную исключения вм
    exclude_vm=`echo $vm_name | grep -E "$exclude_vm_regexp"`
    # если переменная $exclude_vm пуста, то данная вм не исключена начинаем ее бэкапить
    if [ -z "$exclude_vm" ]; then
        # создаем каталог по имени вм
        mkdir -p "$backup_dir/$vm_name"

        # проверяем статус вм если она запущена, надо сохранить ее статус 
        if [ "$vm_state" == "shutoff" ]; then
            msg 0 "$vm_name is shut off"
        else
            msg 0 "$vm_name is running, save state..."
            # определяем имя state файла
            state_file="$backup_dir/$vm_name/$vm_name""_$backup_date.state"
            # сохраняем статус текущей вм в файл
            virsh save $vm_name $state_file > /dev/null 2>&1
            #touch /tmp/ololo
            if [ $? -eq 0 ]; then
                msg 0 "save state for $vm_name successful"
            else
                msg 2 "save state for $vm_name unsuccessful"
                msg 0 "restore state for $vm_name"
                # если не удалось сохранить статус восстановим машину
                virsh restore $state_file > /dev/null 2>&1
                # и перейдем к следующей вм
                msg 1 "backup $vm_name was skipped"
                continue
            fi
        fi
        # после того как сохранили статус вм пойдем по всем lvm томам этой машины
        # подготавливаем имя файла для сохранения настроек libvirtd для этой вм (xml)
        dumpxml_file="$backup_dir/$vm_name/$vm_name""_$backup_date.xml"
        # сохраняем настройки вм в каталог бэкапа
        virsh dumpxml $vm_name > $dumpxml_file
        
        # устанавливаем флаг сброса, будет использован для пропуска бэкапа таких девайсов как floppy и cdrom
        skip_flag=0
        # цикл по всем строкам конфигурационного файла xml текущей вм
        # строки содержащие source dev, ource file, <disk type
        # тк диски вм могут быть файлами или блочными девайсам
        # строку <disk type читаем, что бы определить тип девайса: жеский диск, флопик или дисковод
        grep -E 'source dev|source file|<disk type' "$dumpxml_file" | while read str; do
            # определяем имя логического тома lvm - <source dev='/dev/vg02/zm'/> будет zm
            lv=`echo "$str" | sed -n "s/^.*<source \(dev\|file\)='\(.*\)'\/>/\2/p"`
            # определяем тип девайса - <disk type='block' device='disk'> будет disk
            device=`echo "$str" | sed -n "s/^.*<disk .* device='\(.*\)'.*>/\1/p"`
            # определим переменную для floppy|cdrom те если это один из этих девайсов, переменная будет заполнена
            skip_device=`echo "$device" | grep -E 'floppy|cdrom'`

            # флаг может быть установлен только в предыдущей итерации, если девасй флоппи или cdrom
            # те если текущий $lv является файлом образа дискеты или iso образ диска то пропускаем эту итерацию цикла 
            if [ "$skip_flag" == "1" ]; then
                msg 1 "file $lv for vm: $vm_name was skipped because it is $skip_device"
                skip_flag=0
                continue
            fi
            
            # если переменная $skip_device не пустая, то девайс в следующей строке надо игнорировать, установим для этого флаг, который сделает пропуск в следующей итерации
            if [ -n "$skip_device" ]; then
                skip_flag=1
            fi
            
            # если это строка вида <disk ...> то переходим к следующей строке
            # тк как строки идут чередованием
            # <disk ...
            # <source ...
            # <disk ...
            # <source ...
            if [ -n "$device" ]; then
                continue
            fi

            # заполняем переменную $exclude_lv и если она она будет не пустая то данный том lvm будет пропущен
            exclude_lv=`echo $lv | grep -E "$exclude_lv_regexp"`
            if [ -z "$exclude_lv" ]; then
                # проверяем что можем читать файл блочного устройства или файл вм
                if [ -r "$lv" ]; then
                    # определяем имя тома
                    lv_name=`basename $lv`
                    # определяем путь до тома
                    lv_dir=`dirname $lv`
                    # устанавливаем имя снапшота тома, это имя тома + суффикс
                    lv_name_snapshot="$lv_name""$lv_suffix"
                    # полный путь до снапшота
                    lv_filename_snapshot="$lv_dir/$lv_name_snapshot"
                    # имя файла в которое будет сохранен том, полный путь
                    backup_file="$backup_dir/$vm_name/$lv_name""_$backup_date.raw.gz"
                    # имя файла для сохранения информации по тому командой lvdisplay
                    lvdisplay_file="$backup_dir/$vm_name/$lv_name""_$backup_date.lvdisplay"

                    # сохраняем информацию по тому
                    lvdisplay $lv > $lvdisplay_file

                    # если уже такой снапшот есть, например остался от прошлого запуска, попробуем его удалить, если нет, то идем к следующему тому, а этот пропускаем
                    if [ -b "$lv_filename_snapshot" ]; then
                        lvremove -f "$lv_filename_snapshot" > /dev/null 2>&1
                        if [ $? -ne 0 ]; then
                            msg 2 "can not remove old snapshot - $lv_filename_snapshot of vm: $vm_name"
                            msg 1 "vm: $vm_name was skipped because old snapshot exists"
                            continue
                        fi
                    fi

                    # создаем снапшот
                    lvcreate -s -n"$lv_name_snapshot" -L512M $lv > /dev/null 2>&1
                    #touch /tmp/ololo
                    # если снапшот удачно создался то записываем это в лист для далнейшей обработки
                    # если произошла ошибка то переходим к следующему тому
                    if [ $? -eq 0 ]; then
                        msg 0 "snapshot $lv_name_snapshot of vm: $vm_name was successful created"
                        echo "$lv_filename_snapshot $backup_file" >> $lv_backup_list
                    else
                        msg 2 "snapshot $lv_name_snapshot of vm: $vm_name was unsuccessful created"
                        continue
                    fi
                else
                    # указанный том в xml вм не существует
                    msg 1 "$lv of vm: $vm_name not exists"
                fi
            else
                # данный том исключен регулярным выражением в $exclude_lv_regexp
                msg 1 "$lv has been excluded vm: $vm_name, set in exclude_lv_regexp"
            fi
        done
        # после того как прошли по всем томам текущей машины и создали им снапшоты востанавливаем работу вм
        if [ "$vm_state" != "shutoff" ]; then
            virsh restore $state_file > /dev/null 2>&1
            #touch /tmp/ololo
            if [ $? -eq 0 ]; then
                msg 0 "vm $vm_name was successful restored"
            else
                # если восстановить не удалось идем к следующей вм
                msg 2 "error: vm $vm_name was unsuccessful restored"
                continue
            fi
        fi
    else
        # вм была исключена в $exclude_vm_regexp
        msg 1 "$vm_name has been excluded, set in exclude_vm_regexp"
    fi
    echo ""
done

# бежим по созданному списку и бэкапим все тома
cat "$lv_backup_list" | while read s; do 
    if_file=`echo "$s" | cut -d' ' -f1`
    of_file=`echo "$s" | cut -d' ' -f2`
    
    msg 0 "starting backup $if_file at `date`"
    dd status=none conv=sync,noerror if="$if_file" | gzip > "$of_file"
    if [ $? -eq 0 ]; then
        msg 0 "backup $if_file to $of_file successful"
    else 
        msg 2 "backup $if_file to $of_file unsuccessful"
    fi
    msg 0 "finished backup $if_file at `date`"
    lvremove -f "$if_file" > /dev/null 2>&1
    echo ""
done

rm -f "$lv_backup_list"

