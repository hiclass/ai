# CUBRID 백업/checkdb 정합성 검사 병렬화 실증

`cubrid backupdb` 의 사전 정합성 검사와 `cubrid checkdb` 가 단일 스레드로 도는 문제를
checkdb 로 먼저 실증한 결과입니다. 결론부터:

| 항목 | 결과 |
|---|---|
| 2번 (파일 단위 병렬화) 1단계: 엔진 수정 없이 checkdb 프로세스 N개 | 4프로세스에서 **3.5배** (177.6s → 51.0s) |
| 2번 2단계: 엔진 패치, 서버 워커 N개 (`checkdb_worker_count`) | 4워커에서 **4.7배** (175.0s → 36.9s), 2워커에서 이미 3.0배 |
| backupdb 전체 (검사 포함) | 10.2s → 7.0s. 이 버전(11.5)의 backupdb 사전 검사는 4GB DB 기준 4초로 싸고, 비싼 것은 checkdb 만 수행하는 힙↔인덱스 교차 검사(160s) |
| 3번 (파일 내부 병렬화) | 미구현. B-tree 는 가능, 힙은 비용 대비 이득이 작음 (아래 판단 근거) |

모든 실행은 `rc=0`, 서버 에러 로그에 오류 없음. 정합성 판정 결과는 직렬과 동일(모두 정상).

## 산출물

| 파일 | 내용 |
|---|---|
| `0001-parallel-consistency-check.patch` | CUBRID 엔진 패치 (`src/` 만, 3파일). 기준 커밋 CUBRID/cubrid `8ab924b` (develop, 11.5.0) |
| `scripts/` | 데이터 생성, DB 구성, 1단계/2단계 실행기, 전체 벤치, gdb 스택 샘플러 |
| `results.txt` | 벤치마크 원본 로그 |

## 패치 내용

세 파일, 560줄 추가.

- `src/base/system_parameter.[ch]`: 서버 파라미터 `checkdb_worker_count` 추가 (정수, 기본 1, 1~64, `SET SYSTEM PARAMETERS` 로 런타임 변경 가능). 1이면 기존 직렬 코드가 그대로 돈다.
- `src/transaction/boot_sr.c`: `xboot_check_db_consistency` 에 병렬 경로 추가.
  - 클래스 단위 검사(힙 페이지, 그 클래스의 B-tree, 힙↔인덱스 교차 검사)를 **병렬 쿼리 워커풀** (`parallel_query::worker_manager`, `max_parallel_workers` 로 상한) 에 태스크로 분배한다. 새 워커풀을 등록하지 않으므로 스레드 예산 변경이 없다.
  - 워커는 히스토그램 샘플러/병렬 스캔과 같은 방식으로 요청 트랜잭션을 빌려 쓴다 (`tran_index`, `conn_entry`, `m_px_orig_thread_entry`). 따라서 클래스 잠금과 MVCC 스냅샷이 공유되고, 인터럽트(Ctrl-C)도 전파된다.
  - 클래스는 힙 페이지 수로 내림차순 정렬해 가장 가벼운 버킷에 배정(LPT). 워커 수만큼 버킷을 만들어 태스크 하나가 버킷 하나를 처리한다.
  - 워커의 에러는 스레드 지역이므로 `er_get_area_error` 로 복사해 두고, 요청 스레드가 `er_set_area_error` 로 다시 올린다. 클라이언트는 실제 원인 메시지를 받는다.
  - checkdb 테이블 지정 경로는 기존 `xboot_checkdb_table` 을 그대로 태스크에서 호출한다. 전체 DB 경로(backupdb 가 쓰는 경로)는 루트 힙에서 클래스 목록을 모아 플래그에 맞는 검사만 클래스별로 수행한다. 뷰(힙 없음)는 건너뛴다.
  - 직렬로 남는 것: 디스크/파일 트래커/카탈로그/클래스명 검사(싸다), 모든 repair 모드, prev-link 검사, SA 모드, 워커 확보 실패 시.

사용법:

```
# cubrid.conf 또는 런타임
csql -u dba testdb -c "SET SYSTEM PARAMETERS 'checkdb_worker_count=4'"
cubrid checkdb -C testdb            # 이후 checkdb / backupdb 의 검사가 병렬로 돈다
cubrid backupdb -C -D /backup testdb
```

## 측정 환경

| 항목 | 값 |
|---|---|
| CPU / 메모리 | Xeon 2.1GHz 4코어, 15GB |
| CUBRID | develop `8ab924b` (11.5.0) + 패치, RelWithDebInfo, GCC 13.3 |
| DB | 24테이블 10.8M행 (100만행×8, 30만행×8, 5만행×8), 테이블당 PK + INT 인덱스 + VARCHAR 인덱스, 볼륨 4.1GB |
| 버퍼 | `data_buffer_size=512M` (데이터 > 버퍼 상황), OS 페이지 캐시에는 전부 올라감 (디스크 I/O 0) |
| 측정 | 워밍업 1회 후 각 구성 2회, 표는 평균 |

## 결과

### 1단계: checkdb 프로세스 N개 (엔진 수정 없음)

테이블 목록을 행 수 기준 LPT 로 N개 버킷에 나누고 `cubrid checkdb -C -i bucket_i.txt` 를 동시에 실행.

| 프로세스 | 시간(s) | 배속 |
|---|---|---|
| 1 | 177.6 | 1.0 |
| 2 | 94.7 | 1.9 |
| 4 | 51.0 | 3.5 |
| 8 | 53.6 | 3.3 |

클래스 잠금이 IS 라 프로세스끼리 충돌하지 않고, 4코어에서 3.5배까지 나온다. **병렬화 자체가 유효하다는 것을 코드 수정 없이 확인**한 셈이고, 당장 운영에서도 쓸 수 있는 우회법이다(단, 파일 트래커/카탈로그 전체 검사는 한 번만 별도 실행).

### 2단계: 서버 워커 N개 (패치)

| 워커 | checkdb 테이블 목록(s) | checkdb 전체 DB(s) | 배속(전체 DB) |
|---|---|---|---|
| 1 (직렬, 기존 코드) | 172.3 | 175.0 | 1.0 |
| 2 | 57.4 | 58.0 | 3.0 |
| 4 | 38.8 | 36.9 | 4.7 |
| 8 | 57.9 | 54.8 | 3.2 |

- 4코어에서 4.7배. 1→2 에서 3배가 나오는 초선형 구간이 있는데, 원인은 아래 분석 참조.
- 8워커는 4워커보다 느리다. 코어 수를 넘는 워커는 래치/CPU 경합만 늘린다. **워커 수 상한은 코어 수**로 두는 것이 맞다.

### backupdb 와 검사 종류별 비용

| 실행 | 1워커(s) | 4워커(s) |
|---|---|---|
| `backupdb -C -z` (사전 검사 포함, 4.1GB → 1.1GB) | 10.2 | 7.0 |
| checkdb, backupdb 와 같은 플래그 (파일트래커+힙+카탈로그+B-tree+클래스명) | 4.0 | 1.6 |
| checkdb `--check-btree-entries` (힙↔인덱스 교차 검사만) | 160.3 | 36.2 |

**이 버전에서 backupdb 사전 검사는 4GB 당 4초**다. checkdb 기본 실행(175s)의 90% 이상은 backupdb 가 하지 않는 교차 검사다. 따라서 "백업이 느린 것이 정합성 검사 때문"이라면 (a) 사용 중인 버전의 backupdb 플래그 구성이 다르거나, (b) DB 가 페이지 캐시보다 커서 디스크 I/O 지연에 묶인 경우일 가능성이 크다. (b) 라면 직렬 검사는 페이지마다 I/O 지연을 한 번씩 기다리므로 병렬화 효과가 여기서 잰 것보다 더 클 수 있고, 반대로 HDD 라면 랜덤 I/O 증가로 역효과도 가능하다. 운영 DB 에서 `cubrid checkdb -C --check-heap --check-btree --check-file-tracker --check-catalog --check-class-name` 의 시간을 재 보면 backupdb 검사 비용을 바로 알 수 있다.

### 초선형 배속의 원인

직렬 교차 검사 중 서버 스레드 스택을 gdb 로 25회 샘플링하니 18회가 `locator_check_btree_entries → heap_does_exist → pgbuf_fix → fileio_read → pread` 였다. 인덱스 순서로 항목을 훑으며 항목마다 힙 페이지를 랜덤하게 고정하는데, 거의 전부 버퍼 미스다. `/proc/<cub_server>/io` 로 센 read 시스템콜:

| 실행 | pread 호출 | 읽은 양 |
|---|---|---|
| 직렬 | 14.1M | 231 GB |
| 4워커 | 1.15M | 19 GB |

4GB DB 를 직렬은 약 55번 다시 읽고, 4워커는 약 5번 읽는다. 단일 스레드는 CUBRID 페이지 버퍼의 스레드별 private LRU 할당량에 묶여 작업 집합(테이블 하나의 힙 ≈ 230MB)을 유지하지 못하고, 여러 워커는 합산 할당량이 커져 버퍼 적중률이 올라간다. 즉 병렬화의 이득 일부는 CPU 가 아니라 **버퍼 히트율**에서 온다. 같은 이유로 `data_buffer_size` 를 키우는 것만으로도 직렬 교차 검사가 빨라질 것이다(미측정).

### 미해결 관찰

1단계 2프로세스(94.7s)와 2단계 2워커(57.4s)는 같은 함수(`xboot_checkdb_table`)를 같은 버킷 구성으로 두 스레드에서 돌리는데 차이가 난다. 별도 트랜잭션/별도 private LRU 할당 차이로 추정하지만 확인하지 않았다.

## 3번 (파일 내부 병렬화) 판단

구현하지 않았다. 코드를 읽은 결론:

- **B-tree**: `btree_check_pages` (`btree.c:8694`) 가 루트 자식 서브트리별 재귀라 자식 단위 태스크 분할이 가능하다. `btree_verify_subtree` 가 서브트리 최대 키를 부모로 올려 순서를 검증하므로 경계 키 병합 로직이 필요하다. checkdb `-I 인덱스명` 으로 단일 인덱스 시간을 격리해 잴 수 있어 실증 harness 는 있다.
- **힙**: 체인 순회가 현재 페이지에서 다음 페이지 번호를 읽는 구조이고, 파일 테이블 순회(`heap_check_all_pages_by_file_table`)는 SA 모드 전용으로 컴파일된다. 재배치 검사(`heap_chkreloc`)가 힙 전체를 한 해시로 보므로 분할하면 해시 공유/병합이 필요하고 순환 검출은 순차 순회에 의존한다.
- 이번 측정에서 가장 큰 테이블 하나가 전체 시간을 지배하지 않았고(4워커에서 4.7배), 비싼 교차 검사는 이미 클래스 단위로 잘 나뉜다. 파일 내부 분할은 테이블 하나가 DB 대부분을 차지하는 경우에만 의미가 있다.

## 패치의 한계와 다음 단계

- **옵션 전달**: 지금은 서버 파라미터로만 켠다. `checkdb`/`backupdb` 에 `--thread-count` 를 붙이려면 요청 패킷(`network_interface_cl.c:4265`, `network_interface_sr.cpp:4258`)에 필드를 추가해야 한다. backupdb 의 기존 `-t` 는 백업 읽기 스레드용이라 겸용 여부는 결정이 필요하다.
- **기본값**: 1(직렬)로 두었다. 운영 적용 시 `min(코어 수, 4~8)` 정도가 적절하고, 8워커 결과대로 코어 수 초과는 금지해야 한다.
- **잠금 수명**: 전체 DB 경로는 클래스별 조건부 IS 잠금을 쓰며, DDL 중인 클래스는 건너뛴다(직렬 파일 트래커 순회와 같은 best-effort). 수집 후 삭제된 클래스는 에러로 보고될 수 있다(미발생, 재현 테스트 필요).
- **디버그 빌드**: `heap_check_heap_file` 의 NDEBUG 전용 assert 가 SCH_S 잠금을 기대한다. 기존 `xboot_checkdb_table` 도 IS 로 호출하므로 같은 조건이지만 디버그 빌드 검증은 하지 않았다.
- **테스트**: 정상 DB 에서만 돌렸다. 손상 DB 에서 직렬과 같은 판정/메시지를 내는지, 인터럽트(Ctrl-C) 전파, 워커 전부 사용 중일 때 직렬 폴백을 추가 검증해야 한다.
- **스타일**: CUBRID 의 indent 규칙으로 정리 전이다.

## 재현

```
# 빌드 (GCC 13 환경에서는 -Werror, TBB_STRICT, pl_engine gradle, nlist.h 때문에 로컬 우회가 필요했음. 패치와 무관)
scripts/env.sh          # CUBRID 설치 경로 설정
scripts/setup_db.sh 1.0 # createdb + loaddb(10.8M행) + server start
REPS=2 scripts/bench.sh # 1단계/2단계 전체, 결과는 $WORK/results.txt
scripts/run_stage2.sh 4 xcheck    # 교차 검사만 4워커
scripts/sample_stacks.sh 25 2     # 실행 중 서버 스택 샘플링
```
