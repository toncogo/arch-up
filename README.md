# ArchUp

> Backup, restauração e auditoria de integridade para sistemas **Arch Linux**, com armazenamento externo identificado por rótulo ou UUID.

**ArchUp** é um utilitário interativo em Bash para criar snapshots compactados do sistema, mantê-los em um dispositivo externo e verificar sua integridade antes de uma recuperação. Foi pensado para reduzir o risco de perder uma instalação funcional após atualizações, testes ou erros de configuração.

> [!WARNING]
> A restauração grava arquivos no diretório de destino e pode sobrescrever arquivos existentes. Leia a confirmação exibida pelo programa e teste o fluxo em um ambiente não crítico antes de depender dele em produção.

## Funcionalidades atuais

- Interface de terminal (TUI) com menu, cores, mensagens de estado e barra de progresso.
- Criação de backups completos do sistema em `tar.zst`, com compressão paralela via Zstandard.
- Exibição dinâmica dos caminhos processados durante a criação do backup.
- Exclusão de áreas efêmeras: `/proc`, `/sys`, `/dev`, `/run`, `/tmp`, `/mnt`, `/media`, `/lost+found` e o cache de pacotes do pacman.
- Estimativa de espaço antes da cópia, incluindo margem de segurança de 5%.
- Detecção e montagem do dispositivo pelo `LABEL` ou `UUID` definidos no `.env`.
- Retenção automática: somente os **dois snapshots mais recentes** e seus respectivos arquivos `.hmac` são preservados.
- Assinatura de integridade HMAC-SHA256 do hash SHA-256 de cada arquivo de backup.
- Recuperação interativa com validação obrigatória do HMAC antes da extração.
- Auditoria de integridade: assinatura HMAC, teste `zstd` e validação da estrutura `tar`.
- Inventário do sistema em `libs.txt`: pacotes instalados, pacotes explicitamente instalados e bibliotecas compartilhadas.
- Visão de armazenamento com arquivos, tamanhos, datas, caminhos absolutos e ocupação do dispositivo.
- Logs separados para backup e restauração/auditoria, com rotação automática ao atingir 1 MiB.

## Requisitos

- Arch Linux ou distribuição compatível com `pacman`.
- Permissão administrativa (`sudo`).
- Dispositivo externo com espaço suficiente e um rótulo de sistema de arquivos exclusivo.
- Dependências: `bash`, `tar`, `zstd`, `pv`, `openssl`, `util-linux`, `coreutils`, `findutils`, `gawk`, `sed` e `pacman`.

Instale os pacotes que normalmente fornecem as dependências principais:

```bash
sudo pacman -S --needed bash tar zstd pv openssl util-linux coreutils findutils gawk sed
```

## Instalação e configuração

1. Mantenha estes arquivos juntos em uma pasta privada:

   ```text
   ArchUp.sh
   .env
   ```

2. Torne o script executável:

   ```bash
   chmod 700 ArchUp.sh
   ```

3. Crie o arquivo `.env` na mesma pasta do script:

   ```dotenv
   TARGET_DEVICE_LABEL="ARCHUP_BACKUP"
   MOUNT_POINT="/mnt/archup_backup"
   HASH_SECRET_KEY="gere-uma-chave-longa-unica-com-ao-menos-16-caracteres"
   ```

4. Proteja o arquivo de configuração, pois ele contém a chave usada para validar os backups:

   ```bash
   chmod 600 .env
   ```

5. Execute o programa:

   ```bash
   sudo ./ArchUp.sh
   ```

### Sobre `TARGET_DEVICE_LABEL`

Use o rótulo do sistema de arquivos do pendrive/SSD, por exemplo `ARCHUP_BACKUP`. O script procura primeiro por `LABEL=<valor>` e, se não encontrar, tenta o mesmo valor como UUID. Também é possível escrever explicitamente:

```dotenv
TARGET_DEVICE_LABEL="UUID=seu-uuid-aqui"
```

Confira o rótulo e o UUID disponíveis antes de configurar:

```bash
lsblk -f
```

> [!IMPORTANT]
> O rótulo deve identificar somente o dispositivo destinado ao ArchUp. Evite reutilizar o mesmo rótulo em outros discos.

## Como usar

Após iniciar, escolha uma das opções do menu:

| Opção | O que faz |
| --- | --- |
| `1. Criar Backup` | Confere espaço, compacta o sistema e cria `archup_AAAAMMDD_HHMMSS.tar.zst` e seu arquivo `.hmac`. |
| `2. Recuperação` | Lista os backups, valida a assinatura, pede o destino e exige a confirmação literal `RESTORE`. |
| `3. Verificar Integridade` | Audita todos os backups encontrados, verificando HMAC, compressão Zstandard e estrutura TAR. |
| `4. Consultar Bibliotecas` | Atualiza `libs.txt` no dispositivo com o inventário de pacotes e bibliotecas. |
| `5. Armazenamento` | Mostra os arquivos mantidos, seus caminhos e a ocupação do dispositivo. |
| `6. Sair` | Encerra o programa e desmonta o dispositivo se ele tiver sido montado pelo ArchUp. |

### Recuperação segura

Por padrão, o destino sugerido é `/`, o que caracteriza uma recuperação do sistema. Para inspecionar ou recuperar arquivos sem afetar o sistema em uso, informe antes um diretório existente, por exemplo:

```bash
sudo mkdir -p /mnt/archup-restore-test
```

Depois, use `/mnt/archup-restore-test` como destino no menu. O script não permite restaurar dentro do próprio dispositivo de backup.

## Arquivos gerados

| Arquivo | Finalidade |
| --- | --- |
| `archup_*.tar.zst` | Snapshot compactado do sistema. |
| `archup_*.tar.zst.hmac` | Assinatura HMAC associada exclusivamente ao snapshot. |
| `libs.txt` | Inventário atualizado de pacotes e bibliotecas do sistema. |
| `archup_backup.log` | Registro das operações de criação de backup. |
| `archup_restore.log` | Registro de restaurações, verificações e alertas. |

Os logs ficam ao lado de `ArchUp.sh`. Quando alcançam **1 MiB**, o conteúdo mais antigo é removido e os aproximadamente **500 KiB mais recentes** são preservados.

## Recomendações importantes

- Faça um backup inicial logo após uma instalação estável e outro sempre antes de atualizações grandes, mudanças no kernel, drivers gráficos ou testes de baixo nível.
- Guarde o dispositivo em local seguro e desconectado quando não estiver em uso; isso reduz a exposição a falhas elétricas, ransomware e exclusões acidentais.
- Não altere manualmente um arquivo `.tar.zst` nem seu `.hmac`. Uma divergência interrompe a restauração por segurança.
- Não perca nem troque `HASH_SECRET_KEY` depois de criar backups: sem a mesma chave, os HMACs antigos não poderão ser validados.
- Guarde a chave em um gerenciador de senhas. Não a versione, publique ou envie junto com o dispositivo.
- Use um sistema de arquivos Linux no dispositivo externo, como ext4, para preservar melhor permissões, ACLs e atributos estendidos.
- Faça testes de recuperação em um diretório alternativo ou máquina virtual. Backup só é confiável depois que a recuperação foi testada.
- O ArchUp é uma camada de recuperação local; mantenha também uma cópia adicional dos seus dados realmente insubstituíveis em outro local.

## Limitações conhecidas

- O backup é um snapshot de arquivos, não uma imagem de disco: ele não recria tabela de partições, bootloader ou configuração de firmware automaticamente.
- A restauração sobrescreve caminhos presentes no backup, mas não remove arquivos extras que existirem no destino.
- O conteúdo excluído deliberadamente — como `/tmp`, `/run` e o cache do pacman — não será restaurado.
- A estimativa de espaço é baseada no tamanho descompactado; o arquivo final pode ser menor devido à compressão, mas o programa opera de forma conservadora.

## Segurança

O script usa `set -Eeuo pipefail`, `umask 077`, confirmação explícita antes de restaurar e permissões `600` nos backups, nas assinaturas e no inventário. Mesmo assim, execute-o apenas após revisar sua configuração e em uma sessão administrativa confiável.

---

Feito para que a manutenção do Arch Linux seja mais previsível: crie, verifique e teste seus backups antes de precisar deles.
