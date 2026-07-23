import os
import sys
import time
from playwright.sync_api import sync_playwright

# =====================================================================
# [모듈 1] HTML 대시보드 생성 함수
# =====================================================================
def create_tistory_dashboard():
    txt_path = "tistory_final_report.txt"
    html_path = "tistory_dashboard.html"
    
    if not os.path.exists(txt_path):
        print(f"에러: {txt_path} 파일이 없습니다.")
        return

    with open(txt_path, "r", encoding="utf-8") as f:
        lines = f.readlines()
    
    stats = lines[1].strip() if len(lines) > 1 else ""
    urls = [line.strip() for line in lines if "tistory.com" in line]

    html_content = f"""
    <!DOCTYPE html>
    <html lang="ko">
    <head>
        <meta charset="UTF-8">
        <title>티스토리 구독 관리 대시보드</title>
        <style>
            body {{ font-family: 'Pretendard', sans-serif; background-color: #f4f7f6; color: #333; padding: 40px; }}
            .container {{ max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 12px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); }}
            h1 {{ color: #e84c3d; border-bottom: 2px solid #eee; padding-bottom: 15px; }}
            .stats {{ background: #fff5f5; padding: 15px; border-radius: 8px; font-weight: bold; margin-bottom: 25px; color: #d32f2f; }}
            table {{ width: 100%; border-collapse: collapse; }}
            th, td {{ text-align: left; padding: 15px; border-bottom: 1px solid #eee; }}
            th {{ background-color: #f9f9f9; }}
            .btn-link {{ background-color: #e84c3d; color: white; text-decoration: none; padding: 8px 16px; border-radius: 6px; font-size: 0.9em; transition: 0.3s; display: inline-block; }}
            .btn-link:hover {{ background-color: #c0392b; transform: translateY(-1px); }}
            .url-text {{ font-family: monospace; color: #555; }}
            .row-done {{ background-color: #f9f9f9 !important; }}
            .row-done .url-text {{ color: #bbb; text-decoration: line-through; }}
            .row-done .btn-link {{ background-color: #ccc; }}
            input[type="checkbox"] {{ transform: scale(1.3); cursor: pointer; }}
        </style>
    </head>
    <body>
        <div class="container">
            <h1>📊 티스토리 맞구독 관리</h1>
            <div class="stats">{stats}</div>
            
            <table>
                <thead>
                    <tr>
                        <th width="60">체크</th>
                        <th>블로그 주소</th>
                        <th width="120">동작</th>
                    </tr>
                </thead>
                <tbody>
    """

    for i, url in enumerate(urls):
        html_content += f"""
                    <tr id="row{i}">
                        <td><input type="checkbox" id="check{i}" onclick="toggleRow({i})"></td>
                        <td class="url-text">{url}</td>
                        <td><a href="{url}" target="_blank" class="btn-link" onclick="autoMark({i})">방문하기</a></td>
                    </tr>
        """

    html_content += """
                </tbody>
            </table>
        </div>
        
        <script>
            // 방문하기 버튼 클릭 시 자동으로 체크박스 체크 및 스타일 변경
            function autoMark(i) {
                const checkbox = document.getElementById('check' + i);
                checkbox.checked = true;
                toggleRow(i);
            }

            // 체크박스 클릭 시 스타일 토글
            function toggleRow(i) {
                const row = document.getElementById('row' + i);
                if (document.getElementById('check' + i).checked) {
                    row.classList.add('row-done');
                } else {
                    row.classList.remove('row-done');
                }
            }
        </script>
    </body>
    </html>
    """

    with open(html_path, "w", encoding="utf-8") as f:
        f.write(html_content)
    
    print(f"✅ 대시보드 파일이 성공적으로 생성되었습니다: {os.path.abspath(html_path)}")


# =====================================================================
# [모듈 2] 티스토리 전수 조사 로직
# =====================================================================
def run_persistent_checker():
    with sync_playwright() as p:
        print("="*60)
        print("티스토리 전수 조사 (Playwright 로딩 검증 강화 + HTML 자동 생성)")
        print("="*60)
        
        profile_dir = os.path.join(os.getcwd(), "tistory_session")
        if not os.path.exists(profile_dir): os.makedirs(profile_dir)

        browser_context = p.chromium.launch_persistent_context(
            user_data_dir=profile_dir,
            headless=False,
            args=["--no-sandbox"]
        )
        page = browser_context.new_page()

        print("1. 티스토리 피드로 이동합니다.")
        page.goto("https://www.tistory.com/feed")

        try:
            page.wait_for_selector(".link_info, .txt_num, a:has-text('로그아웃')", timeout=10000)
            print("✅ 로그인 확인 완료.")
        except:
            print("❗ 로그인이 필요합니다. 로그인을 완료해 주세요.")
            page.wait_for_selector(".link_info, .txt_num, a:has-text('로그아웃')", timeout=300000)
            print("✅ 로그인 확인 완료.")

        def collect_data(base_url, target_name):
            print(f"\n[{target_name}] 수집 시작...")
            
            # 페이지 내 아이템 로드를 대기하는 보조 함수
            def wait_for_page_items(timeout=15):
                deadline = time.time() + timeout
                while time.time() < deadline:
                    has_items = page.evaluate("!!document.querySelector('a.info_g, a.box_desc, a.link_info')")
                    if has_items:
                        return True
                    time.sleep(0.5)
                return False

            # 현재 페이징 컨트롤에서 active 페이지 번호를 읽는 보조 함수
            def get_active_page_num():
                return page.evaluate("""
                    (() => {
                        let em = document.querySelector('.paging_tistory em.link_paging');
                        if (!em) return null;
                        return em.innerText.replace('현재페이지', '').trim();
                    })()
                """)

            # 첫 페이지 로드
            page.goto(base_url)
            
            if not wait_for_page_items(20):
                print("   [WARN] 첫 페이지 아이템 로드가 지연되어 추가 대기합니다...")
                time.sleep(10)
            time.sleep(5)  # 렌더링 안정화
            
            all_urls = set()
            current_page = 1
            
            while True:
                # 1. 하단 콘텐츠까지 로드하기 위해 스크롤
                page.evaluate("window.scrollBy(0, 5000)")
                time.sleep(3)
                
                # 2. 블로그 URL 수집
                urls = page.evaluate("""
                    Array.from(document.querySelectorAll('a.info_g, a.box_desc, a.link_info'))
                        .map(a => a.href)
                        .filter(href => href && href.includes('.tistory.com') && !href.includes('www.tistory.com'))
                """) or []
                
                prev_count = len(all_urls)
                for u in urls:
                    clean_url = u.split('?')[0].split('/manage')[0].rstrip('/')
                    if clean_url:
                        all_urls.add(clean_url)
                
                new_found = len(all_urls) - prev_count
                print(f" > {current_page}페이지: {len(urls)}개 발견, 신규 {new_found}개 (누적: {len(all_urls)}명)")

                # 3. 다음 페이지 버튼 탐색 및 클릭
                next_page = current_page + 1
                next_page_str = str(next_page)

                click_script = f"""
                (() => {{
                    let links = document.querySelectorAll('.paging_tistory a.link_paging');
                    for (let link of links) {{
                        if (link.innerText.trim() === '{next_page_str}') {{
                            link.click();
                            return 'NUM_{next_page_str}';
                        }}
                    }}
                    let nextBtn = document.querySelector('.paging_tistory .ico_next');
                    if (nextBtn) {{
                        nextBtn.click();
                        return 'NEXT_BATCH';
                    }}
                    return 'NOT_FOUND';
                }})()
                """

                click_result = page.evaluate(click_script)

                # 버튼을 찾지 못한 경우, 스크롤 후 재시도 (최대 3회)
                retry_count = 0
                while (not click_result or click_result == "NOT_FOUND") and retry_count < 3:
                    print(f"   [!] {next_page_str}페이지 버튼을 찾지 못해 스크롤 후 재시도 중... ({retry_count + 1}/3)")
                    page.evaluate("window.scrollBy(0, 3000)")
                    time.sleep(3)
                    click_result = page.evaluate(click_script)
                    retry_count += 1

                if not click_result or click_result == "NOT_FOUND":
                    print("   버튼을 찾지 못했습니다. 마지막 페이지입니다.")
                    break

                print(f"   액션: {click_result} 클릭됨. 페이지 전환 대기...")

                # 4. 페이지 전환 감지 로직 (<em class="link_paging"> 변화 추적)
                target_num = next_page_str if click_result.startswith("NUM_") else None
                transitioned = False

                for _ in range(40):  # 최대 20초 대기 (0.5초 간격)
                    active = get_active_page_num()
                    if target_num:
                        # 숫자 버튼 클릭 시: 정확한 번호 일치 확인
                        if active == target_num:
                            transitioned = True
                            break
                    else:
                        # '다음페이지' 클릭 시: 현재 페이지 번호에서 벗어남을 확인
                        if active and active != str(current_page):
                            next_page = int(active)  # 실제 이동한 페이지 번호 반영
                            transitioned = True
                            break
                    time.sleep(0.5)

                if transitioned:
                    print(f"   ✅ {next_page}페이지 전환 확인 완료.")
                    # 전환 후 새로운 아이템들이 렌더링될 때까지 대기
                    wait_for_page_items(10)
                    time.sleep(2)
                else:
                    print(f"   [WARN] 페이지 전환 감지 실패 (active={get_active_page_num()}). 5초 추가 대기 후 계속합니다.")
                    time.sleep(5)
                    wait_for_page_items(10)

                current_page = next_page
            
            print(f" > {target_name} 최종 수집 완료: 총 {len(all_urls)}명")
            return all_urls

        # 실행
        subscribers = collect_data("https://www.tistory.com/feed?type=follower", "나를 구독 중")
        followings = collect_data("https://www.tistory.com/feed?type=following", "내가 구독 중")

        not_mutual = sorted(list(followings - subscribers))

        print("\n" + "="*50)
        print(f"📊 최종 분석 결과")
        print(f"- 내가 구독 중: {len(followings)}명")
        print(f"- 나를 구독 중: {len(subscribers)}명")
        print(f"- 맞구독 안 함: {len(not_mutual)}명")
        print("="*50)

        if not_mutual:
            print(f"\n⚠️ 맞구독하지 않은 블로그 ({len(not_mutual)}명):")
            for url in not_mutual:
                print(f"- {url}")
            
            with open("tistory_final_report.txt", "w", encoding="utf-8") as f:
                f.write(f"티스토리 맞구독 결과 (정밀 분석)\n")
                f.write(f"구독 중({len(followings)}) | 구독자({len(subscribers)})\n\n")
                for url in not_mutual:
                    f.write(f"{url}\n")
        else:
            print("\n✅ 모두 맞구독 중입니다!")

        # -------------------------------------------------------------
        # [두 파이썬 파일 통합 지점] 
        # 원본 로직에서 txt 파일 생성이 완료된 직후(엔터 누르기 전)에
        # 방금 만든 txt 파일을 읽어 HTML로 만들어주는 함수를 호출합니다.
        # -------------------------------------------------------------
        print("\n[시스템] 추출된 데이터를 바탕으로 HTML 대시보드를 생성합니다...")
        create_tistory_dashboard()
        # -------------------------------------------------------------

        input("\n모든 분석 및 HTML 생성이 완료되었습니다. 엔터를 눌러 브라우저를 종료하세요...")
        browser_context.close()

if __name__ == "__main__":
    run_persistent_checker()
