// Here you can set window size
var width = 800
var height = 600

// Apply window size at start
window.resizeTo(width, height);

// Center window
window.moveTo(
    (screen.width - width) / 2, 
    (screen.height - height) / 2
);

// Function to send message from JS to BATCH ( Sends to path )
function shell(path, msg, visible) {
  try {
    var shellApp = new ActiveXObject("Shell.Application");
    var fs = new ActiveXObject("Scripting.FileSystemObject");

    // Путь к текущему HTA-файлу
    var rawPath = decodeURIComponent(window.location.pathname);
    if (rawPath.charAt(0) === "/" && rawPath.charAt(2) === ":") {
      rawPath = rawPath.slice(1); // Убираем лишний слеш
    }

    // Путь к папке "bat"
    var parentFolder = fs.GetParentFolderName(rawPath);
    var batFolder = fs.BuildPath(parentFolder, "bat");

    // Полный путь к .bat файлу
    var batFile = fs.BuildPath(batFolder, path.message);

    // Подготавливаем аргументы (без кавычек!)
    var arguments = "";
    if (msg && msg.message) {
      arguments = msg.message; // без кавычек!
    }

    // Собираем команду (путь и аргумент в кавычках вместе)
    var fullCommand = "\"" + batFile + "\" " + arguments;
    // Запуск от имени администратора
    shellApp.ShellExecute("cmd.exe", "/k " + fullCommand, "", "runas", visible || 1);

  } catch (e) {
    var errorMessage = "Ошибка запуска скрипта:\n";
    errorMessage += e.message;
    alert(errorMessage);
  }
}
function txt(path, msg, visible) {
  try {
    var shell = new ActiveXObject("WScript.Shell");
    var fs = new ActiveXObject("Scripting.FileSystemObject");

    // Путь к текущему HTA-файлу
    var rawPath = decodeURIComponent(window.location.pathname);
    if (rawPath.charAt(0) === "/" && rawPath.charAt(2) === ":") {
      rawPath = rawPath.slice(1); // Убираем лишний слеш в начале пути
    }

    // Путь к папке "lists"
    var parentFolder = fs.GetParentFolderName(rawPath);
    var listsFolder = fs.BuildPath(parentFolder, "lists");

    // Полный путь к файлу
    var filePath = fs.BuildPath(listsFolder, path.message);

    // Подготавливаем аргумент как строку в кавычках
    var quotedMsg = "";
    if (msg && msg.message) {
      quotedMsg = "\"";
      quotedMsg += msg.message;
      quotedMsg += "\"";
    }

    // Собираем команду для запуска Блокнота
    var command = "\"";
    command += filePath;
    command += "\" ";
    command += quotedMsg;

    // Запуск Notepad
    shell.Run("notepad.exe " + command, visible || 1, false);

  } catch (e) {
    var errorMessage = "Ошибка открытия файла:\n";
    errorMessage += e.message;
    alert(errorMessage);
  }
}

function shellDefinite(path,visible) {
  try {
    var shellApp = new ActiveXObject("Shell.Application");
    var fs = new ActiveXObject("Scripting.FileSystemObject");

    // Путь к текущему HTA-файлу
    var rawPath = decodeURIComponent(window.location.pathname);
    if (rawPath.charAt(0) === "/" && rawPath.charAt(2) === ":") {
      rawPath = rawPath.slice(1); // Убираем лишний слеш
    }

    // Путь к папке "bat"
    var parentFolder = fs.GetParentFolderName(rawPath);
    var batFolder = fs.BuildPath(parentFolder, "bat");

    // Полный путь к .bat файлу
    var batFile = fs.BuildPath(batFolder, path.message);
    // Запуск от имени администратора
    shellApp.ShellExecute("cmd.exe", "/k " + batFile, "", "runas", visible || 1);

  } catch (e) {
    var errorMessage = "Ошибка запуска скрипта:\n";
    errorMessage += e.message;
    alert(errorMessage);
  }
}