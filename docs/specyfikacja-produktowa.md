# DeskMate — specyfikacja produktowa

## 1. Cel i wartość

DeskMate to piękny, spokojny asystent na Maca dla osób nieprogramujących. Użytkownik szybko go otwiera i zadaje pytanie. Asystent odpowiada z ogólnej wiedzy modelu, z wybranych przez użytkownika plików oraz z podłączonych MCP. Potrafi też przygotować brief, zadania i porównanie jako wynik rozmowy. Działa po angielsku i domyślnie korzysta z lokalnego modelu Apple.

Produkt jest demonstratorem T13: pokazuje wartość AI na sprzęcie Apple i pozwala sprawdzić potrzebę przyszłego narzędzia firmowego. Prototyp ma być użyteczny samodzielnie, bez konta i bez płatnego API modelu. Nie jest gotowym wdrożeniem enterprise.

## 2. Odbiorca i najważniejszy przebieg

Pierwszy odbiorca to Marek oraz uczestnik pokazu T13 pracujący na angielskich materiałach biznesowych. Osoba rozumie swoje zadanie, ale nie musi znać promptowania, modeli ani terminala.

Przebieg: skrót klawiszowy, menu bar lub widget → kompaktowe okno rozmowy → pytanie po angielsku → dobór wiedzy modelu, relevantnych fragmentów wskazanych plików i narzędzi MCP → odpowiedź z widocznymi źródłami → pytanie uzupełniające lub zapis wyniku. Gdy potrzebny jest kontekst z MCP, aplikacja pokazuje docelowy serwer, narzędzie i argumenty przed każdym wywołaniem.

Dostarczamy od razu pełen prototyp obejmujący rozmowę, własne pliki, MCP, widget i szybki panel. Pierwszy wewnętrzny checkpoint implementacyjny to prawdziwa odpowiedź modelu w estetycznym oknie rozmowy. To kontrola postępu, nie ograniczenie dostawy ani osobna bramka zgody na dalszy zakres. Odbiór Marka dotyczy całego przebiegu.

## 3. Zakres działającego prototypu

| Obszar | Kontrakt |
| --- | --- |
| Interfejs | Natywny macOS, język angielski, jasny i ciemny motyw, wygodna klawiatura i dostępność |
| Rozmowa | Pytania i follow-upy po angielsku, streaming odpowiedzi, anulowanie, nowa rozmowa, pamięć bieżącej rozmowy w granicach kontekstu |
| Wiedza modelu | Odpowiedź bez plików jest dozwolona; brak live web i gwarancji aktualnej wiedzy; jawne odróżnienie od znalezionych źródeł |
| Brief | Summary, Decisions, Open questions, Next steps; brakująca informacja oznaczona, nigdy wymyślona jako fakt |
| Zadania | Task, Owner, Due date, Evidence; owner/termin tylko z materiału, inaczej Not specified |
| Porównanie | Dwa wskazane dokumenty, tabela różnic, braków i pytań; wynik z odwołaniem do właściwego materiału |
| Materiały | Wklejony tekst, UTF-8 TXT/Markdown i PDF z warstwą tekstową; do pięciu załączników w pytaniu, do dwóch w jawnie wybranym porównaniu; biblioteka do 200 obsługiwanych plików w wybranych folderach; PDF do 10 MB i 50 stron na plik |
| My files | Użytkownik dodaje foldery lub pojedyncze pliki; tekstowy indeks lokalny i wyszukiwanie potrzebnych fragmentów; foldery przez jawne uprawnienie, bez skanowania całego dysku |
| Kontekst | Jawny limit dopasowany do rzeczywistego contextSize; długi materiał opracowywany etapami lub odrzucony z instrukcją; bez cichego obcięcia |
| Wynik | Edycja, Copy, Save as Markdown; źródła oddzielone od generowanych wniosków |
| Historia | Lokalny zapis rozmów i wyników, ponowne otwarcie, usunięcie oraz Clear history |
| Dostęp | Główne okno, kompaktowy panel, menu bar i natywny widget desktopowy w rozmiarze small/medium |
| MCP | Ręcznie dodany Streamable HTTP endpoint, lista narzędzi, jawne włączenie wybranych narzędzi, podgląd i potwierdzenie każdego wywołania |

Niepełny lub nieczytelny PDF jest oznaczony; skany wymagające OCR nie są przyjmowane jako poprawnie odczytany tekst. Użytkownik zawsze widzi, które źródła faktycznie weszły do zadania. Limity plików nie gwarantują zmieszczenia w kontekście.

## 4. Jakość doświadczenia

DeskMate ma wyglądać jak dopracowane narzędzie macOS. Stonowany akcent, czytelna typografia, subtelne materiały, mało dekoracji, wyraźne źródło i wynik. Konkretne tokeny i reguły są w `design-system.md`.

Ekran startowy stawia kursor w composerze i pokazuje podpowiedzi: Ask about my files, Summarize a meeting, Compare documents. Kompaktowy panel jest pełnoprawną rozmową, umożliwia pytania uzupełniające i dodanie plików. Główne okno rozszerza rozmowę, bibliotekę i konfigurację MCP. Źródła i wywołania narzędzi są zwijane pod odpowiedzią; wynik można skopiować lub zapisać. Sformatowany rezultat ma własny edytowalny widok.

Użytkownik może anulować generowanie. Interfejs zachowuje jego materiał po błędzie i umożliwia ponowienie. Nie obiecuje aktualizacji widgetu w czasie rzeczywistym. Opis Local wskazuje miejsce działania modelu; Remote connection wskazuje transmisję do serwera MCP.

## 5. Widget i przypięcie

WidgetKit umożliwia dodanie widgetu przez systemową galerię na pulpit. Small otwiera Ask DeskMate. Medium otwiera New chat, Ask my files albo ostatnią rozmowę i pokazuje ogólny status. Skrót globalny, domyślnie Option+Space z możliwością zmiany i wykryciem konfliktu, otwiera ten sam panel. Menu bar zapewnia alternatywę. Widget jest wejściem do aplikacji; nie zawiera swobodnego pola tekstowego ani wykonania długiego procesu AI.

Kliknięcie otwiera właściwy panel także po zamknięciu aplikacji. Widget odczytuje wyłącznie niewrażliwy snapshot przez App Group. Domyślnie nie pokazuje treści, nazw dokumentów ani fragmentów wyników. Dostępność modelu jest stanem ostatnio sprawdzonym, nie obietnicą aktualizacji na żywo.

Panel ma osobne Pin/Unpin. Przypięcie oznacza pozostanie widocznym podczas pracy w innych aplikacjach; nie jest drugim widgetem ani stałą warstwą nad wszystkimi pełnoekranowymi przestrzeniami. Widoczne okno i widget są sprawdzane na docelowym Macu, nie tylko w preview Xcode.

## 6. Lokalny model i angielski

Bazą jest macOS 26+, Swift/SwiftUI i Foundation Models SystemLanguageModel. Aplikacja przed generowaniem sprawdza dostępność, obsługę angielskiego oraz rozmiar kontekstu. Nie pobiera alternatywnego modelu automatycznie, nie zmienia języka systemu i nie przełącza na chmurę. Użytkownik dostaje jasny komunikat, gdy Apple Intelligence jest wyłączone, model niegotowy lub sprzęt nieobsługiwany.

Wszystkie prompty i UI są angielskie. Wyniki wymagają oceny użytkownika. Współczesny systemowy model ma ograniczony kontekst, więc nie obiecujemy analizy całej bazy firmowej. Wyszukiwanie w wybranej bibliotece jest rzeczywistą częścią prototypu: lokalny indeks tekstu i porcjowanie materiału wystarczają dla pierwszej wersji; nie wymagamy wektorowej bazy ani dodatkowego modelu embeddingów. Ranking służy do znalezienia fragmentów, nie rozumienia intencji za model. Wynik wyszukiwania można obejrzeć; brak trafień nie jest dowodem braku informacji w organizacji. Usunięty lub cofnięty folder znika z wyszukiwania. Refresh aktualizuje dodane i zmienione pliki. Fragmenty dokumentów otrzymują identyfikatory źródła; wskazania źródeł w wyniku muszą odnosić się do faktycznie przekazanych fragmentów. Syntetyczne przykłady służą do porównania jakości.

Nowości macOS 27 z WWDC26, Private Cloud Compute i modele innych dostawców nie są zależnością prototypu. Framework open source nie oznacza swobodnej dystrybucji wag modelu Apple.

## 7. MCP i granica zaufania

MCP jest wykonalne przez oficjalny Swift SDK i adapter do narzędzi Foundation Models. To funkcja aplikacji; nie zakładamy wbudowanego klienta MCP w modelu Apple.

Prototyp obsługuje ręcznie wpisany Streamable HTTP URL: HTTPS oraz jawny loopback HTTP dla serwera demonstracyjnego. Możliwe uwierzytelnienie to opcjonalny token Bearer przechowywany w Keychain. Brak pełnego OAuth i uruchamiania lokalnych procesów stdio w tej wersji. Konfiguracja pozwala Test connection, Enable/Disable, Disconnect/Delete i wybór narzędzi. Komunikaty nie ujawniają tokenów.

Lista narzędzi i ich schematy pochodzą z rzeczywistego serwera. Użytkownik wybiera maksymalnie pięć narzędzi, aby nie zapełniać kontekstu. Adapter waliduje argumenty według obsługiwanego schematu; nieobsługiwane schematy wyłącza z wyjaśnieniem. Model wybiera potrzebne narzędzie i argumenty; kod egzekwuje tożsamość połączenia, uprawnienia i integralność wywołania.

Każde wywołanie wymaga osobnego podglądu: serwer, narzędzie, argumenty i przewidywany przepływ danych. Odrzucenie nie wysyła zapytania. Podgląd jest widoczny w aplikacji, nigdy w widgecie. Automatyczne wywołania oraz zapisy do zewnętrznych systemów nie należą do demonstracyjnego przebiegu. Deklaracja readOnlyHint serwera nie zastępuje kontroli i zgody użytkownika.

Dowód działania: kontrolowany serwer z syntetycznymi informacjami projektu udostępnia dwa narzędzia pobierania kontekstu. Asystent podczas zwykłej rozmowy dobiera je na podstawie pytania użytkownika, odpowiada oraz tworzy brief i pokazuje pochodzenie informacji oraz historię wywołań. Limit sześciu wywołań na zadanie, timeout i ograniczenie rozmiaru odpowiedzi zatrzymują nieskończone lub nadmierne operacje. Błąd, odmowa i rozłączenie dają zrozumiały wynik, bez fałszywego komunikatu o powodzeniu.

Treści serwera, plików i opisów narzędzi są danymi niezaufanymi. Nie mogą same dodawać połączeń, uprawnień ani uruchamiać kodu. Wersja protokołu jest negocjowana z serwerem zgodnie z przypiętą wersją SDK; nie obiecujemy kompatybilności z każdym MCP ani każdym schematem.

## 8. Dane i architektura

Jedna natywna aplikacja macOS oraz rozszerzenie WidgetKit. SwiftUI dla UI, PDFKit dla PDF, Foundation Models dla lokalnego wnioskowania, App Intents/deep links dla wejścia z widgetu, App Group tylko dla bezpiecznego snapshotu, Keychain dla sekretów MCP. Historia i indeks w lokalnym Application Support z prostym, wersjonowanym zapisem; nie wymaga serwera ani konta.

Aplikacja używa systemowego wyboru plików i ewentualnych security-scoped bookmarks wyłącznie tam, gdzie rzeczywiście potrzebne. Nie skanuje dysku ani schowka w tle. Treść wskazanych plików jest przechowywana w lokalnym indeksie; rozmowy zawierają pytania, odpowiedzi i odwołania do źródeł. Settings wyjaśnia ten zapis i umożliwia Clear history oraz Clear library. Usunięcie źródła usuwa jego indeks i blokuje ponowny odczyt; historyczna odpowiedź pozostaje do usunięcia rozmowy. Sekrety MCP nie trafiają do historii. Usunięcie historii usuwa zapisy aplikacji i snapshot widgetu. Nie gwarantuje kasowania kopii użytkownika ani backupów systemowych.

Preferowany App Sandbox; nie wyłączamy go milcząco w celu obejścia problemów. Entitlements, podpisywanie i App Group wymagają sprawdzenia w realnym buildzie. Ścieżka przyjęcia: lokalna instalacja na Macu Marka; App Store i publiczna dystrybucja są osobnym zakresem.

## 9. Szybkość i uczciwość odpowiedzi

Panel po skrócie lub widgecie ma być gotowy do pisania w ciągu około jednej sekundy przy działającej aplikacji. Pierwsza instalacja, pobieranie modelu i zimny start są pokazywane jako osobne stany. Czas pierwszego tokenu, wyszukiwania i pełnej odpowiedzi mierzymy na docelowym Macu, z modelem gotowym, na krótkich syntetycznych pytaniach; celem jest odczuwalnie szybka rozmowa, nie obietnica stałego czasu dla każdego zadania. Pokazujemy aktywność i umożliwiamy przerwanie bez utraty pytania.

Odpowiedź może łączyć ogólną wiedzę z danymi użytkownika, ale rozróżnia ich pochodzenie. Nie pokazujemy wymyślonych linków do plików ani źródeł MCP. Asystent wyjaśnia, gdy nie znalazł odpowiednich fragmentów lub narzędzie odmówiło dostępu. Historia jest streszczana/ograniczana jawnie przy przekroczeniu kontekstu. Model nie ma nieograniczonej pamięci i nie dostaje uprawnień do całego komputera.

## 10. Kryterium ukończenia prototypu

1. Marek uruchamia zainstalowaną aplikację i dodaje widget na pulpicie.
2. Z widgetu otwiera właściwy panel, przypina go, zadaje pytanie ogólne, otrzymuje prawdziwą odpowiedź modelu, kontynuuje rozmowę i zapisuje wynik.
3. Dodaje folder z syntetycznymi plikami TXT/Markdown/PDF, pyta o informacje bez ręcznego wklejania, sprawdza odwołania i otrzymuje poprawne odpowiedzi na follow-upy. Porównuje dwa dokumenty, edytuje wynik i wraca do rozmowy po restarcie.
4. Gdy model jest niedostępny, zadanie można anulować albo materiał jest zbyt długi, aplikacja uczciwie wyjaśnia stan i zachowuje pracę.
5. Podłącza kontrolowany MCP, wybiera narzędzia i otrzymuje odpowiedź łączącą informacje z plików i zatwierdzonych rzeczywistych wywołań. Asystent sam dobiera potrzebne narzędzie, a użytkownik zatwierdza jego użycie. Odrzucone wywołanie nie trafia do serwera; rozłączenie i usunięcie tokena działają.
6. Lokalny przebieg działa bez sieci; transmisja MCP jest jawnie odróżniona. Widget nie ujawnia wrażliwych treści.
7. UI przechodzi kontrolę wizualną jasnego/ciemnego motywu, małego/dużego okna, klawiatury, VoiceOver i ograniczonego ruchu.
8. Repo opisuje rzeczywiste polecenia build/install oraz ograniczenia. Wyniki testów nie zastępują demonstracji realnego modelu i widgetu.

Samo utworzenie repozytorium i backlogu nie oznacza realizacji tych kryteriów. WBS, statusy i zależności są utrzymywane wyłącznie w GitHub Issues i Project.

## 11. Poza prototypem

Whisper i nagrywanie audio, OCR skanów, skanowanie całego dysku, semantyczny indeks dużej bazy enterprise, live web search, model lokalny innego dostawcy, PCC, iOS/iPadOS, synchronizacja, konta, enterprise SSO, marketplace MCP, OAuth, stdio/shell, autonomiczne zapisy i agent działający bez nadzoru, App Store oraz szeroki hardening. Kierunki te można wybrać po ocenie pełnego prototypu.

## 12. Podstawa techniczna

- [Apple: Foundation Models](https://developer.apple.com/documentation/foundationmodels)
- [Apple: SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)
- [Apple: widget extension — ograniczenia text input i wejście do aplikacji](https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension)
- [Apple: interactive widgets](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)
- [Oficjalny MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)

Źródła uzasadniają wybór technologii, nie potwierdzają implementacji DeskMate. Wersje API i pakietów należy sprawdzić przy pierwszym buildzie i przypiąć zależności.
