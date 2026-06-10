#include "lwip/dhcp.h"
#include "lwip/inet.h"
#include "lwip/init.h"
#include "lwip/tcp.h"
#include "lwip/timeouts.h" // 타이머 처리를 위해 추가
#include "netif/xadapter.h"
#include "xil_printf.h"
#include "xllfifo.h"
#include "xparameters.h"
#include <lwip/def.h>
#include "sleep.h"

XLlFifo FifoInstance;
ip_addr_t ipaddr, netmask, gw;
struct netif server_netif;
static void print_ip_settings(ip_addr_t *ip, ip_addr_t *mask, ip_addr_t *gw);
static void print_ip(char *msg, ip_addr_t *ip);

void init_audio_network();

err_t recv_callback(void *arg, struct tcp_pcb *tpcb, struct pbuf *p,
                    err_t err) {

  /* do not read the packet if we are not in ESTABLISHED state */
  if (!p) {
    tcp_close(tpcb);
    tcp_recv(tpcb, NULL);
    return ERR_OK;
  }

  uint16_t payload_len = p->tot_len;
  uint32_t *audio_data = (uint32_t *)p->payload;

  // AXI Stream FIFO의 빈 공간(Vacancy) 확인
  // 오디오 데이터 크기보다 FIFO 여유 공간이 많을 때만 Write
  u32 vacancy = XLlFifo_TxVacancy(&FifoInstance);

  if (vacancy >= (payload_len / 4)) {
    // 패킷 페이로드를 AXI Stream FIFO 내부 FIFO로 버스트 기입
    for (int i = 0; i < (payload_len / 4); i++) {
      uint32_t data = audio_data[i];
      XLlFifo_TxPutWord(&FifoInstance, data);
    }
    // 기입 완료 후 PL 영역으로 실제 전송 시작 명령 리로드
    XLlFifo_iTxSetLen(&FifoInstance, payload_len);
  } else {
    xil_printf("wait %d bytes (TX FIFO full) \r\n", payload_len);
    return ERR_INPROGRESS;
  }

  /* indicate that the packet has been received */
  tcp_recved(tpcb, p->len);

  // lwIP 메모리 버퍼 해제 (필수)
  pbuf_free(p);

  return ERR_OK;
}

err_t accept_callback(void *arg, struct tcp_pcb *newpcb, err_t err) {
  static int connection = 1;

  /* set the receive callback for this connection */
  tcp_recv(newpcb, recv_callback);

  /* just use an integer number indicating the connection id as the
     callback argument */
  tcp_arg(newpcb, (void *)(UINTPTR)connection);

  /* increment for subsequent accepted connections */
  connection++;

  return ERR_OK;
}

void init_audio_network() {
  struct tcp_pcb *pcb;
  pcb = tcp_new_ip_type(IPADDR_TYPE_ANY);
  if (!pcb) {
    xil_printf("Error creating PCB. Out of Memory\n\r");
    return;
  }

  // TCP 5004번 포트로 바인딩
  err_t err = err = tcp_bind(pcb, IP_ANY_TYPE, 5004);
  if (err != ERR_OK) {
    xil_printf("Unable to bind to port %d: err = %d\n\r", 5004, err);
    return;
  }
  tcp_arg(pcb, NULL);
  pcb = tcp_listen(pcb);
  if (!pcb) {
    xil_printf("Out of memory while tcp_listen\n\r");
    return;
  }
  tcp_accept(pcb, accept_callback);
}

#define DEFAULT_IP_ADDRESS "10.114.0.10"
#define DEFAULT_IP_MASK "255.255.255.0"
#define DEFAULT_GW_ADDRESS "10.114.0.1"

static void assign_default_ip(ip_addr_t *ip, ip_addr_t *mask, ip_addr_t *gw) {
  int err;

  xil_printf("Configuring default IP %s \r\n", DEFAULT_IP_ADDRESS);

  err = inet_aton(DEFAULT_IP_ADDRESS, ip);
  if (!err)
    xil_printf("Invalid default IP address: %d\r\n", err);

  err = inet_aton(DEFAULT_IP_MASK, mask);
  if (!err)
    xil_printf("Invalid default IP MASK: %d\r\n", err);

  err = inet_aton(DEFAULT_GW_ADDRESS, gw);
  if (!err)
    xil_printf("Invalid default gateway address: %d\r\n", err);
}

int main() {
  XLlFifo_Config *Config;
  int Status;
  Status = XST_SUCCESS;
  Config = XLlFfio_LookupConfig(XPAR_XLLFIFO_0_BASEADDR);
  /*
   * This is where the virtual address would be used, this example
   * uses physical address.
   */
  Status = XLlFifo_CfgInitialize(&FifoInstance, Config, Config->BaseAddress);
  if (Status != XST_SUCCESS) {
    xil_printf("Initialization failed\n\r");
    return Status;
  }

  /* Check for the Reset value */
  Status = XLlFifo_Status(&FifoInstance);
  XLlFifo_IntClear(&FifoInstance, 0xffffffff);
  Status = XLlFifo_Status(&FifoInstance);
  if (Status != 0x0) {
    xil_printf("\n ERROR : Reset value of ISR0 : 0x%x\t"
               "Expected : 0x0\n\r",
               XLlFifo_Status(&FifoInstance));
    return XST_FAILURE;
  }

  struct netif *netif;
  lwip_init();
  unsigned char mac_ethernet_address[] = {0x00, 0x0a, 0x35, 0x00, 0x01, 0x02};
  netif = &server_netif;
  /* Add network interface to the netif_list, and set it as default */
  if (!xemac_add(netif, NULL, NULL, NULL, mac_ethernet_address,
                 XPAR_XEMACPS_0_BASEADDR)) {
    xil_printf("Error adding N/W interface\r\n");
    return -1;
  }
  netif_set_default(netif);
  netif_set_up(netif);
  /* Create a new DHCP client for this interface.
   * Note: you must call dhcp_fine_tmr() and dhcp_coarse_tmr() at
   * the predefined regular intervals after starting the client.
   */
  dhcp_start(netif);
  int dhcp_timoutcntr = 2000;
  while (((netif->ip_addr.addr) == 0) && (dhcp_timoutcntr > 0)) {
    xemacif_input(netif);
    dhcp_timoutcntr--;
    msleep(1);
    if (dhcp_timoutcntr <= 0) {
      if ((netif->ip_addr.addr) == 0) {
        xil_printf("ERROR: DHCP request timed out\r\n");
        assign_default_ip(&(netif->ip_addr), &(netif->netmask), &(netif->gw));
      }
    }
  }

  print_ip_settings(&(netif->ip_addr), &(netif->netmask), &(netif->gw));

  init_audio_network();
  xil_printf("TCP Audio Server Started. Listening on port 5004...\r\n");

  while (1) {
    // 이더넷 맥으로부터 패킷을 계속 읽어서 lwIP 스택 및 콜백으로 던져줌
    xemacif_input(netif);

#if LWIP_TIMERS
    sys_check_timeouts();
#endif
  }
}

static void print_ip_settings(ip_addr_t *ip, ip_addr_t *mask, ip_addr_t *gw) {
  print_ip("Board IP:       ", ip);
  print_ip("Netmask :       ", mask);
  print_ip("Gateway :       ", gw);
}

static void print_ip(char *msg, ip_addr_t *ip) {
  print(msg);
  xil_printf("%d.%d.%d.%d\r\n", ip4_addr1(ip), ip4_addr2(ip), ip4_addr3(ip),
             ip4_addr4(ip));
}
