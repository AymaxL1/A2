// Roxy 的 CDP 面。本票只落**端点构造这一个纯函数**;探测(ps/lsof)与真去 GET/PUT 归 02 票的执行侧。
//
// 单独成文件是因为这里有本次移植**唯一一个直译会出错的地方**(见 02 研究票
// `docs/research/url-router-ts-port-facts.md` 结论 2):
//
//   母本把整条目标 URL 塞进 `/json/new` 的 query,编码用 Swift 的 `.urlQueryAllowed` —— 那个字符集
//   **不含 `#`**,所以 fragment 的井号被编成 `%23`,整条 URL 完好地作为一个 query 传过去。
//   JS 的 `encodeURI` **恰恰保留 `#`**。照着换,`https://claude.ai/x#frag` 到了 `/json/new?` 里
//   就成了「query = https://claude.ai/x,fragment = frag」——Chrome 只看 query,打开的是被截断的 URL。
//   丢的还偏偏是 fragment:单页应用的会话/定位全在那儿,现象是"打开了,但不是那一页",
//   没人会想到去怪编码。
//
// `encodeURIComponent` 不是替代品:它把 `:` `/` 也编掉,与母本传出去的字节不同,属于另一种改写。

/**
 * 把目标 URL 编成 `/json/new?` 后面那一段。
 *
 * 等价于母本的 `absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`:
 * `encodeURI` 的保留集与 `.urlQueryAllowed` 只差一个 `#`,补上就对齐了。
 */
export function encodeCdpTargetURL(url: string): string {
  return encodeURI(url).replaceAll("#", "%23");
}

/** `/json/new?<url>` 的完整端点(恒回环 —— 内核不对回环以外的地址发一个字节)。 */
export function cdpNewTabEndpoint(port: number, url: string): string {
  return `http://127.0.0.1:${port}/json/new?${encodeCdpTargetURL(url)}`;
}
