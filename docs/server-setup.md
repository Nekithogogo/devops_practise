# Конфигурация виртуальной машины devops-vm

Документ описывает, как с нуля (со снимка `01-clean-install`) восстановить конфигурацию сервера.
Команды с пометкой **[VM]** выполняются на сервере, **[Хост]** — на рабочей станции (Windows 10, Git Bash).

## 1. Параметры машины

| Параметр | Значение |
|---|---|
| Гипервизор | Oracle VirtualBox 7.1.8 |
| Имя ВМ / имя узла | `devops-vm` (FQDN `devops-vm.devops.local`) |
| Гостевая ОС | Ubuntu Server 24.04 LTS (64-bit), образ `ubuntu-24.04-server-cloudimg-amd64` |
| Оперативная память | 2048 МБ |
| Процессор | 2 ядра |
| Диск | 25 ГБ, VDI, динамически расширяемый (`devops-vm.vdi`) |
| Часовой пояс | Europe/Moscow |

Особенность установки: вместо интерактивного установщика использован официальный cloud-образ Ubuntu Server 24.04
и cloud-init (NoCloud, ISO `seed.iso` с `user-data`/`meta-data`/`network-config`). Через cloud-init заданы
имя узла `devops-vm`, пользователь `student` (группа `sudo`) с паролем и DHCP на обоих адаптерах.
После первой загрузки cloud-init отключён (`/etc/cloud/cloud-init.disabled`), ISO извлечён.

Создание ВМ (**[Хост]**, PowerShell/Git Bash, `VBoxManage`):

```bash
VBoxManage createvm --name devops-vm --ostype Ubuntu_64 --register
VBoxManage modifyvm devops-vm --memory 2048 --cpus 2 --nic1 nat --nic2 hostonly \
  --hostonlyadapter2 "VirtualBox Host-Only Ethernet Adapter" --natpf1 "ssh,tcp,127.0.0.1,2222,,22"
VBoxManage clonemedium disk noble.vmdk devops-vm.vdi --format VDI
VBoxManage modifymedium disk devops-vm.vdi --resize 25600
VBoxManage storagectl devops-vm --name SATA --add sata --controller IntelAhci --portcount 2
VBoxManage storageattach devops-vm --storagectl SATA --port 0 --device 0 --type hdd --medium devops-vm.vdi
VBoxManage storageattach devops-vm --storagectl SATA --port 1 --device 0 --type dvddrive --medium seed.iso
VBoxManage startvm devops-vm --type headless
```

Первичная настройка (**[VM]**): `sudo apt update && sudo apt upgrade -y`, `sudo timedatectl set-timezone Europe/Moscow`.

## 2. Сетевые интерфейсы

| Адаптер | Тип VirtualBox | Интерфейс | Адрес | Назначение |
|---|---|---|---|---|
| 1 | NAT | `enp0s3` | `10.0.2.15/24` (DHCP VirtualBox) | доступ в Интернет (apt), SSH через проброс порта |
| 2 | Host-only (`VirtualBox Host-Only Ethernet Adapter`, хост `192.168.56.1`) | `enp0s8` | `192.168.56.101/24` (DHCP `192.168.56.100`) | прямой доступ с хоста: веб-сервер, `devops.local` |

На хосте в `C:\Windows\System32\drivers\etc\hosts` добавлена строка `192.168.56.101 devops.local`
(после этого `ipconfig /flushdns`).

На сервере в `/etc/hosts`: `127.0.1.1 devops-vm.devops.local devops-vm` (в cloud-образе строки `127.0.1.1` не было —
она добавлена, а не заменена через `sed`), `hostname -f` → `devops-vm.devops.local`.

## 3. Правило проброса портов

| Имя | Протокол | Адрес хоста | Порт хоста | Адрес гостя | Порт гостя |
|---|---|---|---|---|---|
| `ssh` | TCP | 127.0.0.1 | 2222 | — | **2222** (до усиления защиты SSH — 22) |

```bash
VBoxManage controlvm devops-vm natpf1 delete ssh
VBoxManage controlvm devops-vm natpf1 "ssh,tcp,127.0.0.1,2222,,2222"
```

## 4. Учётные записи

| Имя | UID | Группы | Аутентификация по SSH |
|---|---|---|---|
| `student` | 1000 | student, adm, sudo | запрещена (`AllowUsers devops`); вход только с консоли ВМ по паролю |
| `devops` | 1001 | devops, sudo, users (с ПР № 7 — также docker) | только по ключу `~/.ssh/devops_vm` (ed25519); пароль нужен для `sudo` |
| `root` | 0 | — | вход запрещён (`PermitRootLogin no`, `disable_root`) |

Пароли `student` и `devops` хранятся вне репозитория.

```bash
# [VM]
sudo adduser devops            # задать пароль
sudo usermod -aG sudo devops
# [Хост]
ssh-keygen -t ed25519 -C "devops-vm-key" -f ~/.ssh/devops_vm
ssh-copy-id -i ~/.ssh/devops_vm.pub -p 2222 devops@127.0.0.1
```

Права на сервере: `~/.ssh` — 700, `~/.ssh/authorized_keys` — 600.

`~/.ssh/config` на хосте:

```
Host devops
    HostName 127.0.0.1
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

## 5. Служба SSH

Основной файл `/etc/ssh/sshd_config` не изменяется (копия — `/etc/ssh/sshd_config.backup`).
Изменения — в `/etc/ssh/sshd_config.d/99-hardening.conf`:

```
Port 2222

PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30

AllowUsers devops

X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

**Важно:** в `/etc/ssh/sshd_config.d/50-cloud-init.conf` строка `PasswordAuthentication yes` закомментирована
(иначе она, как первая встреченная, переопределяет значение из `99-hardening.conf`):

```bash
sudo sed -i 's/^PasswordAuthentication yes/#PasswordAuthentication yes/' /etc/ssh/sshd_config.d/50-cloud-init.conf
```

Применение (не закрывая текущую сессию!):

```bash
sudo sshd -t && echo "Конфигурация корректна"
sudo systemctl disable --now ssh.socket       # иначе порт задаёт ssh.socket (22)
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh
sudo ss -tlnp | grep sshd                     # 0.0.0.0:2222
```

Затем на хосте изменить порт гостя в правиле проброса на 2222 (раздел 3) и проверить `ssh devops` в новом терминале.

## 6. Правила межсетевого экрана

Политики: `deny (incoming)`, `allow (outgoing)`, `disabled (routed)`. Журналирование: `medium`.

| Порт | Действие | Комментарий |
|---|---|---|
| 80/tcp | ALLOW IN | HTTP |
| 443/tcp | ALLOW IN | HTTPS |
| 2222/tcp | LIMIT IN | SSH rate-limited (блокировка источника при ≥ 6 соединениях за 30 с) |

(те же правила для IPv6)

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 2222/tcp comment 'SSH rate-limited'   # правило для SSH — ДО включения
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw enable
sudo ufw logging medium
```

Не использовать `ufw allow ssh` — по `/etc/services` это порт 22.

## 7. Снимки состояния

| Снимок | Момент создания | Состояние |
|---|---|---|
| `01-clean-install` | 23.10.2026 06:38 | ОС установлена и обновлена, пользователь `student`, SSH на порту 22 |
| `02-keys-configured` | 23.10.2026 06:39 | пользователь `devops`, вход по ключу, `~/.ssh/config` на хосте |
| `03-ssh-hardened` | 23.10.2026 06:41 | `99-hardening.conf`, порт 2222, проброс 2222→2222 |
| `04-nginx-https` | 23.10.2026 07:02 | Nginx, ресурс `devops.local`, самоподписанный сертификат, HTTP→HTTPS |

## 8. Веб-сервер

**Пакет:** `nginx` (1.24.0, репозиторий Ubuntu): `sudo apt install -y nginx`. Профили UFW `Nginx *` не используются —
порты 80/443 уже открыты правилами из раздела 6.

**Конфигурация ресурса:** `/etc/nginx/sites-available/devops-site` (владелец root, 644), включена символической ссылкой
`/etc/nginx/sites-enabled/devops-site`; стандартный ресурс отключён удалением ссылки `/etc/nginx/sites-enabled/default`
(файл в `sites-available` сохранён).

```nginx
# Блок 1: перенаправление HTTP -> HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name devops.local;

    return 301 https://$host$request_uri;
}

# Блок 2: ресурс по HTTPS
server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name devops.local;

    ssl_certificate     /etc/ssl/certs/devops.crt;
    ssl_certificate_key /etc/ssl/private/devops.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root /var/www/devops-site;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    error_page 404 /404.html;

    access_log /var/log/nginx/devops-site.access.log;
    error_log  /var/log/nginx/devops-site.error.log;
}
```

Применение только так: `sudo nginx -t && sudo systemctl reload nginx` (не `restart`). HSTS не включать.

**Каталог ресурса:** `/var/www/devops-site`, владелец `devops:devops`, каталог `755` (`drwxr-xr-x`), файлы `644`.
`www-data` только читает. Создание:

```bash
sudo mkdir -p /var/www/devops-site
sudo chown -R devops:devops /var/www/devops-site
```

Содержимое доставляется из каталога `site/` репозитория сценарием `scripts/deploy.sh`
(`rsync -avz --delete --chmod=D755,F644`, одно SSH-соединение, проверка `curl --cacert`).

**Сертификат и ключ:**

| Файл | Владелец | Права |
|---|---|---|
| `/etc/ssl/certs/devops.crt` | root:root | 644 |
| `/etc/ssl/private/devops.key` | root:root | 600 (читает только главный процесс nginx) |

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key \
  -out /etc/ssl/certs/devops.crt \
  -subj "/CN=devops.local" \
  -addext "subjectAltName=DNS:devops.local"
```

Срок действия: 365 дней (с 23.10.2026 по 23.10.2027). На хосте копия сертификата — `~/devops.crt`
(`scp devops:/etc/ssl/certs/devops.crt ~/devops.crt`), используется как доверенный CA: `curl --cacert ~/devops.crt`.

**Хост (Windows):** rsync отсутствует в Git Bash — установлен из MSYS2 (`pacman -S rsync openssh`), вызывается обёрткой
`~/bin/rsync`; в `C:\msys64\etc\nsswitch.conf` задано `db_home: windows`, чтобы ssh из MSYS2 читал тот же `~/.ssh/config`.
