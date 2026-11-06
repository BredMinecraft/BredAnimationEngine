# Bred Animation Engine 1.0 — macOS

Natywna aplikacja Swift/AppKit/SwiftUI. Wygląd inspirowany dostarczonymi screenshotami AnimaEngine: ciemna biblioteka, niebieskie zaznaczenia, siatka kart, prawy panel i ustawienia w kartach. Nie zawiera zasobów ani kodu oryginalnej aplikacji. Nie jest pełnym portem wszystkich funkcji AnimaEngine.

## Budowanie

Wymagany macOS 13+ i Apple Command Line Tools (`xcode-select --install`). Rozpakuj projekt, zakończ poprzednią instancję przez ikonę w pasku menu i uruchom w Terminalu:

```bash
bash ~/Downloads/BredAnimationEngine-4/build.command
```

Jeśli folder znajduje się gdzie indziej, użyj właściwej ścieżki. Skrypt tworzy i uruchamia `build/Bred Animation Engine.app`. Aplikację można przenieść do Aplikacji. Budowanie nie pobiera zależności.

## Funkcje

- Biblioteka APNG/PNG/GIF: import, wyszukiwanie, statyczne miniatury, animowany podgląd, podwójny klik uruchamiający postać.
- FPS: Oryginalne, 15, 24, 30, 60, 120. Ustawienia z poprzednich wersji pozostają zgodne; zachowywany jest także zapisany mnożnik szybkości.
- Prosty suwak rozmiaru, obrót -180…180°, odbicie poziome/pionowe. Zmiany działają na żywo, bez przebudowywania APNG.
- Sterowanie przez prawy klik na postaci lub przycisk w bibliotece: krycie, zawsze nad oknami, blokada przeciągania, przepuszczanie kliknięć, ukrywanie pod kursorem, reset i zamknięcie.
- ⌘ + prawy klik nad obszarem postaci próbuje otworzyć sterowanie także przy przepuszczaniu kliknięć. Globalna obserwacja zdarzeń zależy od zgód macOS. Jeśli nie działa, użyj przycisku Sterowanie animacją w bibliotece. Aplikacja nie przechwytuje ani nie blokuje kliknięcia w aplikacji pod spodem.
- Osobne okno edycji na żywo.
- Dźwięk z wybranego pliku obsługiwanego przez AVAudioPlayer: wybór, głośność, zapętlanie, usunięcie powiązania. Dźwięk odtwarza się tylko z postacią na pulpicie; podgląd jest niemy. Audio startuje z postacią, ale nie ma synchronizacji do każdej pętli, przesunięcia w ms ani dopasowania FPS do długości audio. Zmiana pliku audio restartuje dźwięk.
- Narzędzia: otwieranie folderu biblioteki, import i eksport konfiguracji.
- Ustawienia: ukrywanie/pokazywanie postaci, zatrzymanie wszystkich, czyszczenie przygotowanych klatek, dostęp do systemowych ustawień logowania.
- Brak ikony w Docku i ⌘Tab. Bibliotekę otwiera ikona w pasku menu → Pokaż bibliotekę. Program kończy opcja Zakończ.

## Przechowywanie i wydajność

Pliki źródłowe są kopiowane do `~/Library/Application Support/BredAnimationEngine`. Import nie modyfikuje oryginałów. Istniejąca biblioteka i przygotowane klatki są używane ponownie. Pozycje postaci i uruchomione instancje nie są przywracane po restarcie.

Pierwsze otwarcie przygotowuje nieskompresowane klatki RGBA na dysku z paskiem postępu. Maksymalny dłuższy bok klatki wynosi 768 px; duże powiększenie może zmniejszyć ostrość. Rozmiar cache: szerokość × wysokość × 4 × liczba klatek. Aplikacja sprawdza wolne miejsce przed przygotowaniem. Gotowe dane są mapowane z pliku; NSCache przechowuje do 8 obrazów z celem 32 MB na animację. Nie jest to limit całkowitej pamięci procesu.

Czyszczenie cache zatrzymuje postacie, usuwa przygotowane dane i wymusza ponowne przygotowanie. Usunięcie animacji usuwa jej kopię i cache. Odłączone pliki audio mogą pozostać w folderze biblioteki.

Eksport konfiguracji zapisuje JSON bez multimediów. Import przywraca ustawienia wyłącznie dla pasujących identyfikatorów istniejącej biblioteki; nie jest kopią przenoszącą wszystkie pliki na inny komputer.

## Zakres

Workshop pominięto zgodnie z ustaleniem. Brak integracji z Anima Profiles/Triggers, Piskel, usuwania tła przez AI, konwersji MP4, serwera OBS, globalnego skrótu klawiaturowego oraz tłumaczeń interfejsu. Nie dodano pustych kontrolek tych funkcji. Autostart ustawia się ręcznie przez ustawienia macOS.

## Weryfikacja

Projekt przygotowano na Linuxie bez macOS SDK. Sprawdzono składnię skryptu budowania, poprawność Info.plist, zgodność identyfikatora okna z akcją menu i zawartość ZIP. Wersja 1.0 wymaga kompilacji i sprawdzenia na Macu; nie potwierdzono wizualnie zgodności renderowania SwiftUI ani działania globalnego skrótu myszy na docelowym systemie.
