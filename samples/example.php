<?php
// Greets every name in the list.
function greet(array $names): void {
    foreach ($names as $name) {
        echo "Hello, $name!\n";
    }
}

greet(['Ann', 'Boris']);
